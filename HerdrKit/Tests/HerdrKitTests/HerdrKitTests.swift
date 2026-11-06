import Foundation
import Testing
import TerminalCore
@testable import HerdrKit

/// A scripted core: answers hello as a plain line, then speaks frames.
final class FakeCore: ByteTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var reader = FrameReader()
    private var framed = false
    private(set) var sentFrames: [Frame] = []
    /// Answers one JSON-RPC request with the bytes to send back (already framed by the caller).
    var respond: @Sendable (FakeCore, _ id: Int, _ method: String) -> Void = { _, _, _ in }

    init() {
        (incoming, output) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    func send(_ data: Data) async throws {
        var requests: [[String: Any]] = []
        lock.withLock {
            reader.append(data)
            while true {
                if !framed {
                    guard let line = reader.nextLine() else { break }
                    requests.append(try! JSONSerialization.jsonObject(with: line) as! [String: Any])
                } else {
                    guard let frame = try! reader.nextFrame() else { break }
                    sentFrames.append(frame)
                    if frame.channel == 0 {
                        requests.append(try! JSONSerialization.jsonObject(with: frame.payload) as! [String: Any])
                    }
                }
            }
        }
        for request in requests {
            let id = request["id"] as! Int
            let method = request["method"] as! String
            if method == "hello" {
                emit(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"generation":1,"version":"0.1.16","core":{"id":"abc","name":"box"},"framed":true,"methods":[],"features":[]}}"#.utf8) + Data([0x0A]))
                lock.withLock { framed = true }
            } else {
                respond(self, id, method)
            }
        }
    }

    func emit(_ bytes: Data) { output.yield(bytes) }

    func reply(_ id: Int, _ resultJSON: String) {
        emit(Frame(channel: 0, kind: .data, payload: Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#.utf8)).encoded())
    }

    func close() { output.finish() }
}

private let terminalJSON = #"{"address":"t7","argv":["fish"],"cwd":"/tmp","state":"live","title":"~","labels":{"where":"repo / 1"},"cols":80,"rows":24,"created_ms":1}"#

@Test(.timeLimit(.minutes(1))) func handshakeSwitchesToFramedMode() async throws {
    let core = FakeCore()
    core.respond = { core, id, method in
        #expect(method == "terminal.list")
        // The reply split across two chunks, mid-header.
        let frame = Frame(channel: 0, kind: .data, payload: Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"hidden_finished":2,"terminals":[\#(terminalJSON)]}}"#.utf8)).encoded()
        core.emit(frame.prefix(5))
        core.emit(frame.dropFirst(5))
    }
    let client = try await HerdrClient.connect(over: core)
    #expect(await client.hello?.core.name == "box")

    let list = try await client.listTerminals()
    #expect(list.hiddenFinished == 2)
    #expect(list.terminals.first?.displayName == "repo / 1")
    // herdr-core leaves out an empty `machines` (its schema says required).
    #expect(list.machines.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func eventsArriveAndAreCredited() async throws {
    let core = FakeCore()
    core.respond = { core, id, method in
        #expect(method == "events.subscribe")
        core.reply(id, #"{"seq":10,"terminals":[\#(terminalJSON)],"channel":3}"#)
        // Events right behind the reply, one line split across frames.
        let lines = #"{"jsonrpc":"2.0","method":"event","params":{"seq":11,"type":"status","terminal":"t7","data":{"status":{"state":"blocked","msg":"needs you"},"records":{},"reported":true}}}"#
            + "\n" + #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":11}}"# + "\n"
        let bytes = Data(lines.utf8)
        core.emit(Frame(channel: 3, kind: .data, payload: bytes.prefix(40)).encoded())
        core.emit(Frame(channel: 3, kind: .data, payload: bytes.dropFirst(40)).encoded())
    }
    let client = try await HerdrClient.connect(over: core)
    let subscription = try await client.subscribeEvents()
    var snapshot = subscription.snapshot
    #expect(snapshot["t7"]?.status == nil)

    var iterator = subscription.messages.makeAsyncIterator()
    snapshot.apply(try #require(await iterator.next()))
    #expect(snapshot["t7"]?.status?.state == "blocked")
    guard case .heartbeat(11) = try #require(await iterator.next()) else {
        Issue.record("expected a heartbeat")
        return
    }
    // Both chunks were credited back on channel 3.
    try await Task.sleep(for: .milliseconds(50))
    let credited = core.sentFrames.filter { $0.channel == 3 && $0.kind == Frame.Kind.credit.rawValue }.count
    #expect(credited == 2)
}

@Test(.timeLimit(.minutes(1))) func rpcErrorsCarryKind() async throws {
    let core = FakeCore()
    core.respond = { core, id, _ in
        core.emit(Frame(channel: 0, kind: .data, payload: Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"no terminal t9","data":{"kind":"not_found","hint":"try hc ls"}}}"#.utf8)).encoded())
    }
    let client = try await HerdrClient.connect(over: core)
    await #expect {
        let _: TerminalList = try await client.call("terminal.get", ["terminal": "t9"])
    } throws: { error in
        guard case HerdrError.rpc(_, _, let kind, _) = error else { return false }
        return kind == "not_found"
    }
}

@Test(.timeLimit(.minutes(1))) func closedConnectionFailsCalls() async throws {
    let core = FakeCore()
    core.close()
    await #expect(throws: HerdrError.self) { try await HerdrClient.connect(over: core) }
}

@Test func frameRoundTrip() throws {
    var reader = FrameReader()
    let frames = [Frame.credit(channel: 3, bytes: 1024), Frame.resize(channel: 4, cols: 120, rows: 40),
                  Frame(channel: 0, kind: .data, payload: Data("{}".utf8))]
    for frame in frames { reader.append(frame.encoded()) }
    for frame in frames {
        let next = try reader.nextFrame()
        #expect(next == frame)
    }
    let end = try reader.nextFrame()
    #expect(end == nil)
    #expect(Frame.credit(channel: 1, bytes: 258).encoded() == Data([1, 0, 0, 0, 1, 4, 0, 0, 0, 2, 1, 0, 0]))
}

@Test func snapshotAppliesEventsInOrder() throws {
    let terminal = try JSONDecoder().decode(Terminal.self, from: Data(terminalJSON.utf8))
    var snapshot = TerminalSnapshot(seq: 5, terminals: [terminal])
    func event(_ json: String) -> EventMessage { EventMessage.decode(Data(json.utf8))! }

    snapshot.apply(event(#"{"method":"event","params":{"seq":6,"type":"title","terminal":"t7","data":{"title":"vim"}}}"#))
    #expect(snapshot["t7"]?.title == "vim")
    // Stale: not above the current seq.
    let applied = snapshot.apply(event(#"{"method":"event","params":{"seq":6,"type":"title","terminal":"t7","data":{"title":"old"}}}"#))
    #expect(!applied)
    #expect(snapshot["t7"]?.title == "vim")

    snapshot.apply(event(#"{"method":"event","params":{"seq":7,"type":"created","terminal":"t8","data":{"address":"t8","state":"live"}}}"#))
    snapshot.apply(event(#"{"method":"event","params":{"seq":8,"type":"finished","terminal":"t7","data":{"reason":"exited","exit_code":3,"signal":null,"finished_ms":1}}}"#))
    #expect(snapshot["t7"]?.state == "finished")
    #expect(snapshot["t7"]?.exitCode == 3)
    snapshot.apply(event(#"{"method":"event","params":{"seq":9,"type":"removed","terminal":"t7","data":{}}}"#))
    #expect(snapshot.terminals.map(\.address) == ["t8"])

    snapshot.apply(event(#"{"method":"missed","params":{"seq":20,"terminals":[]}}"#))
    #expect(snapshot.terminals.isEmpty)
    #expect(snapshot.seq == 20)
}

/// herdr-core leaves out `machines` when it has no added machines, although its schema requires it.
@Test func decodesListWithoutMachines() throws {
    let json = #"{"hidden_finished":0,"terminals":[{"address":"t1","state":"live"}]}"#
    let list = try JSONDecoder().decode(TerminalList.self, from: Data(json.utf8))
    #expect(list.machines.isEmpty)
    #expect(list.terminals.first?.labels.isEmpty == true)
}

private func terminal(_ address: String, cwd: String = "/tmp", parent: String? = nil, labels: [String: String] = [:],
                      status: String? = nil, turn: UInt64? = nil, created: UInt64 = 0) throws -> Terminal {
    var json: [String: Any] = ["address": address, "state": "live", "cwd": cwd, "labels": labels, "created_ms": created]
    if let parent { json["parent"] = parent }
    if let turn { json["turn"] = turn }
    if let status { json["status"] = ["state": status] }
    return try JSONDecoder().decode(Terminal.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func turnEventsUpdateTheTurn() throws {
    var snapshot = TerminalSnapshot(seq: 1, terminals: [try terminal("t1", status: "working", turn: 2)])
    let line = #"{"method":"event","params":{"seq":2,"type":"turn","terminal":"t1","data":{"turn":3,"state":"done"}}}"#
    snapshot.apply(EventMessage.decode(Data(line.utf8))!)
    #expect(snapshot["t1"]?.turn == 3)
}

/// `status_ms` comes with records; a status event that changes the word moves it (core leaves
/// it out of the event), one that only changes the message doesn't.
@Test func statusEventsMoveTheStatusTime() throws {
    let json = #"{"address":"t1","state":"live","status":{"state":"working"},"status_ms":1000}"#
    var snapshot = TerminalSnapshot(seq: 1, terminals: [try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))])
    #expect(snapshot["t1"]?.statusMs == 1000)
    func status(_ seq: Int, _ data: String) -> EventMessage {
        EventMessage.decode(Data(#"{"method":"event","params":{"seq":\#(seq),"type":"status","terminal":"t1","data":{"status":\#(data)}}}"#.utf8))!
    }
    snapshot.apply(status(2, #"{"state":"working","msg":"still"}"#))
    #expect(snapshot["t1"]?.statusMs == 1000)
    snapshot.apply(status(3, #"{"state":"done"}"#))
    #expect(snapshot["t1"]!.statusMs! > 1000)
}

/// herdr-app's `docs/labels.md`: done while a turn ended after the one last seen.
@Test func agentStateFollowsSharedReadState() throws {
    let seen = Terminal.seenLabel
    #expect(try terminal("t1").agentState == nil)
    #expect(try terminal("t1", labels: [seen: "0"], status: "blocked", turn: 4).agentState == .needsYou)
    #expect(try terminal("t1", labels: [seen: "0"], status: "error", turn: 4).agentState == .error)
    #expect(try terminal("t1", labels: [seen: "0"], status: "working", turn: 4).agentState == .working)
    // Unread, read, whatever the program called it.
    #expect(try terminal("t1", labels: [seen: "3"], status: "idle", turn: 4).agentState == .done)
    #expect(try terminal("t1", labels: [seen: "4"], status: "done", turn: 4).agentState == .idle)
    // Without the label (or a turn), the program's own word.
    #expect(try terminal("t1", status: "done", turn: 4).agentState == .done)
    #expect(try terminal("t1", status: "idle", turn: 4).agentState == .idle)
    #expect(try terminal("t1", labels: [seen: "9"], status: "done").agentState == .done)
}

@Test func seenOnlyRisesExceptForMarkUnread() throws {
    let seen = Terminal.seenLabel
    #expect(try terminal("t1", status: "done", turn: 4).markSeen == [seen: "4"])  // missing: joins
    #expect(try terminal("t1", labels: [seen: "2"], status: "working", turn: 4).markSeen == [seen: "4"])
    #expect(try terminal("t1", labels: [seen: "4"], status: "idle", turn: 4).markSeen == nil)
    #expect(try terminal("t1", labels: [seen: "5"], status: "idle", turn: 4).markSeen == nil)
    #expect(try terminal("t1", status: "done").markSeen == nil)  // core without turns

    #expect(try terminal("t1", labels: [seen: "3"], status: "done", turn: 4).markRead == [seen: "4"])
    #expect(try terminal("t1", labels: [seen: "4"], status: "done", turn: 4).markRead == nil)
    #expect(try terminal("t1", labels: [seen: "4"], status: "idle", turn: 4).markUnread == [seen: "3"])
    #expect(try terminal("t1", labels: [seen: "0"], status: "idle", turn: 0).markUnread == nil)
    #expect(try terminal("t1", labels: [seen: "3"], status: "done", turn: 4).markUnread == nil)
    #expect(try terminal("t1", labels: [seen: "3"], status: "blocked", turn: 4).markUnread == nil)
}

private let layoutJSON = #"""
{"spaces":[
  {"id":"sp1","name":"","folder":"/Users/me","tabs":[
    {"id":"tb1","name":"","root":{"id":"tb1","type":"row","children":[
      {"id":"p1","type":"block","content":{"terminal":"t1"}},
      {"id":"c1","type":"column","children":[{"id":"p2","type":"block","content":{"terminal":"t2"}}]}]}},
    {"id":"tb2","name":"logs","root":{"id":"tb2","type":"row","children":[
      {"id":"p3","type":"block","content":{"terminal":"t3"}},
      {"id":"p4","type":"block","content":{"mod":"notes"}}]}}]},
  {"id":"sp2","name":"herdr ios","folder":"/tmp","tabs":[
    {"id":"tb3","root":{"type":"row","children":[{"type":"block","content":{"terminal":"t9"}}]}}]},
  {"id":"sp3","name":"empty","folder":"/tmp","tabs":[]}
]}
"""#

@Test func parsesHerdrAppLayout() throws {
    let layout = HerdrAppLayout(document: try JSONDecoder().decode(JSONValue.self, from: Data(layoutJSON.utf8)))
    #expect(layout.spaces.map(\.id) == ["sp1", "sp2", "sp3"])
    #expect(layout.spaces[0].tabs.map(\.terminals) == [["t1", "t2"], ["t3"]])
    #expect(layout.spaces[0].tabs[1].name == "logs")
}

@Test func groupsTerminalsLikeHerdrApp() throws {
    let layout = HerdrAppLayout(document: try JSONDecoder().decode(JSONValue.self, from: Data(layoutJSON.utf8)))
    let terminals = [
        try terminal("t1", cwd: "/Users/me/projects/rattler"),
        try terminal("t2", status: "blocked"),
        try terminal("t3"),
        try terminal("t4", parent: "t1", created: 2),          // agent started by t1
        try terminal("t5", parent: "t4", created: 3),          // and its own child
        try terminal("t6", labels: ["herdr.space": "sp2"]),   // worker without a pane
        try terminal("t7"),                                    // hc run --bg
        try terminal("box/t1"),                                // on another machine
        // t9 is in the layout but gone: skipped
    ]
    let sections = TerminalGrouping.bySpace(terminals, layout: layout)
    #expect(sections.map(\.title) == ["rattler", "herdr ios", "box", "Other terminals"])

    let first = sections[0]
    #expect(first.rows.map(\.terminal.address) == ["t1", "t4", "t5", "t2", "t3"])
    #expect(first.rows.map(\.depth) == [0, 1, 2, 0, 0])
    #expect(first.rows.map(\.tab) == ["1", "1", "1", "1", "logs"])
    #expect(first.subtitle == "~")
    #expect(first.needsYou == 1)

    #expect(sections[1].rows.map(\.terminal.address) == ["t6"])
    #expect(sections[1].rows[0].tab == nil)  // single-tab space: no tab labels
    #expect(sections[2].kind == .machine(name: "box"))
    #expect(sections[3].rows.map(\.terminal.address) == ["t7"])
}

@Test func groupingWithoutLayoutStillNestsChildren() throws {
    let sections = TerminalGrouping.bySpace([try terminal("t1"), try terminal("t2", parent: "t1")], layout: nil)
    #expect(sections.map(\.title) == ["Terminals"])
    #expect(sections[0].rows.map(\.depth) == [0, 1])
}

@Test func connectCommandMatchesHerdrCore() {
    #expect(HerdrCore.connectCommand() ==
        #"sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || { echo "herdr-core is not installed here" >&2; exit 127; }; exec "$p" connect'"#)
    #expect(HerdrCore.connectCommand(session: "scratch").contains("HC_SESSION=scratch exec"))
}

@Test func notInstalledIsToldApartFromOtherFailures() {
    let missing = HerdrCore.notInstalledMessage
    #expect(HerdrCore.isNotInstalled(SSHTransportError.commandFailed(exitCode: 127, stderr: missing)))
    // A login script can print around it.
    #expect(HerdrCore.isNotInstalled(SSHTransportError.commandFailed(exitCode: 127, stderr: "Welcome!\n\(missing)")))
    // One that's there but can't start: installing wouldn't help.
    #expect(!HerdrCore.isNotInstalled(SSHTransportError.commandFailed(exitCode: 127, stderr: "libc.so: not found")))
    #expect(!HerdrCore.isNotInstalled(SSHTransportError.commandFailed(exitCode: 1, stderr: missing)))
    #expect(!HerdrCore.isNotInstalled(HerdrError.connectionClosed))
}

#if os(macOS)
/// Runs a command in a real shell that finds only what's in `folder`, its home, and the system's programs.
private func runInShell(_ command: String, folder: URL) throws -> (status: Int32, stderr: String) {
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["PATH": "\(folder.path):/usr/bin:/bin", "HOME": folder.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: stderr, as: UTF8.self))
}

private func emptyFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func connectCommandSaysWhenHerdrCoreIsMissing() throws {
    let folder = try emptyFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = try runInShell(HerdrCore.connectCommand(), folder: folder)
    #expect(HerdrCore.isNotInstalled(SSHTransportError.commandFailed(exitCode: Int(result.status), stderr: result.stderr)))
}

/// `installCommand`'s exit status with this as `curl`: what it prints stands in for the installer.
private func installStatus(curl: String) throws -> Int32 {
    let folder = try emptyFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fake = folder.appending(path: "curl")
    try "#!/bin/sh\n\(curl)\n".write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return try runInShell(HerdrCore.installCommand, folder: folder).status
}

@Test func installCommandReportsHowTheInstallerEnded() throws {
    #expect(try installStatus(curl: "echo 'exit 0'") == 0)
    #expect(try installStatus(curl: "echo 'exit 3'") == 1)
    // Not 127, which would read as "not installed".
    #expect(try installStatus(curl: "echo 'exit 127'") == 1)
}

/// With plain `curl … | sh`, these two would count as installed.
@Test func installCommandFailsWhenTheDownloadFails() throws {
    #expect(try installStatus(curl: "exit 6") == 1)
    #expect(try installStatus(curl: "echo 'exit 0'; exit 18") == 1)
}
#endif

#if os(macOS)
private let localCore = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/herdr-core")

/// Against a real herdr-core in its own session (`herdrkit-test-*`), so your terminals are untouched:
/// subscribe, run a command, and watch it appear and finish.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: localCore.path)), .timeLimit(.minutes(1)))
func localHerdrCoreEvents() async throws {
    let client = try await HerdrClient.connect(
        over: try ProcessTransport(executable: localCore, environment: ["HC_SESSION": "herdrkit-test-events"]))
    let hello = try #require(await client.hello)
    #expect(hello.generation == HerdrCore.generation)

    let subscription = try await client.subscribeEvents()
    var snapshot = subscription.snapshot

    struct Run: Encodable, Sendable { let argv: [String]; let name: String; let rm: Bool }
    struct Ran: Decodable, Sendable { let address: String }
    let ran: Ran = try await client.call("terminal.run", Run(argv: ["sh", "-c", "sleep 0.2; exit 3"], name: "herdrkit-\(UUID().uuidString.prefix(6).lowercased())", rm: false))

    var sawCreated = false
    for try await message in subscription.messages {
        snapshot.apply(message)
        if snapshot[ran.address] != nil { sawCreated = true }
        if snapshot[ran.address]?.state == "finished" { break }
    }
    #expect(sawCreated)
    #expect(snapshot[ran.address]?.exitCode == 3)

    struct Empty: Codable, Sendable {}
    let _: Empty? = try? await client.call("server.stop", Empty())
    await client.close()
}
/// A program reports working, then done (OSC 7501): core counts the turn, in the snapshot and as
/// a `turn` event, and the agent shows as unread until `herdr.seen` reaches it.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: localCore.path)), .timeLimit(.minutes(1)))
func localHerdrCoreTurns() async throws {
    let client = try await HerdrClient.connect(
        over: try ProcessTransport(executable: localCore, environment: ["HC_SESSION": "herdrkit-test-turns"]))
    let subscription = try await client.subscribeEvents()
    var snapshot = subscription.snapshot

    struct Run: Encodable, Sendable { let argv: [String]; let name: String }
    struct Ran: Decodable, Sendable { let address: String }
    let script = #"printf '\033]7501;state=working\033\\'; sleep 0.2; printf '\033]7501;state=done\033\\'; sleep 30"#
    let ran: Ran = try await client.call("terminal.run", Run(
        argv: ["sh", "-c", script], name: "herdrkit-\(UUID().uuidString.prefix(6).lowercased())"))

    var sawTurnEvent = false
    for try await message in subscription.messages {
        if case .event(let event) = message, event.terminal == ran.address, case .turn = event.change { sawTurnEvent = true }
        snapshot.apply(message)
        if sawTurnEvent, snapshot[ran.address]?.status?.state == "done" { break }
    }
    let terminal = try #require(snapshot[ran.address])
    #expect(terminal.turn == 1)
    #expect(terminal.agentState == .done)
    #expect(terminal.statusMs != nil)

    struct Label: Encodable, Sendable { let terminal: String; let labels: [String: String] }
    struct Empty: Codable, Sendable {}
    let _: Empty? = try? await client.call("terminal.label", Label(terminal: ran.address, labels: try #require(terminal.markSeen)))
    for try await message in subscription.messages {
        snapshot.apply(message)
        if snapshot[ran.address]?.seenTurn == 1 { break }
    }
    #expect(snapshot[ran.address]?.agentState == .idle)

    let _: Empty? = try? await client.call("server.stop", Empty())
    await client.close()
}

/// Attach to a real terminal, render it with libghostty-vt, type into it, and see it exit.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: localCore.path)), .timeLimit(.minutes(1)))
func localHerdrCoreAttach() async throws {
    let client = try await HerdrClient.connect(
        over: try ProcessTransport(executable: localCore, environment: ["HC_SESSION": "herdrkit-test-attach"]))
    struct Run: Encodable, Sendable { let argv: [String]; let name: String }
    struct Ran: Decodable, Sendable { let address: String }
    let ran: Ran = try await client.call("terminal.run", Run(
        argv: ["sh", "-c", "printf 'hello from herdr\\r\\n'; exec cat"],
        name: "herdrkit-\(UUID().uuidString.prefix(6).lowercased())"))

    let vt = try VirtualTerminal(cols: 40, rows: 6)
    let attached = try await client.attach(terminal: ran.address, cols: 40, rows: 6)
    var output = attached.output.makeAsyncIterator()

    func waitFor(_ text: String) async throws {
        while !vt.frame().text.contains(text) {
            guard let chunk = try await output.next() else { throw StreamEnd(reason: "eof", exitCode: nil) }
            vt.write(chunk)
        }
    }
    try await waitFor("hello from herdr")

    // Typed keys go through the terminal's line discipline and cat echoes them back.
    try await attached.send(Data("typed".utf8) + vt.encode(.enter))
    try await waitFor("typed\ntyped")

    // Ctrl-D ends cat; the stream closes with the exit reason.
    try await attached.send(vt.encode(.letter("d"), modifiers: .control))
    await #expect {
        while let chunk = try await output.next() { vt.write(chunk) }
    } throws: { error in
        (error as? StreamEnd)?.reason == "exited" && (error as? StreamEnd)?.exitCode == 0
    }

    struct Empty: Codable, Sendable {}
    let _: Empty? = try? await client.call("server.stop", Empty())
    await client.close()
}
/// Write a layout document like herdr-app does, see the change event, read it back.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: localCore.path)), .timeLimit(.minutes(1)))
func localHerdrCoreLayoutDocument() async throws {
    let client = try await HerdrClient.connect(
        over: try ProcessTransport(executable: localCore, environment: ["HC_SESSION": "herdrkit-test-layout"]))
    let subscription = try await client.subscribeEvents()
    let current = try await client.document(named: HerdrAppLayout.documentName)

    struct Set: Encodable, Sendable { let name: String; let value: JSONValue; let version: UInt64 }
    struct Written: Decodable, Sendable { let version: UInt64 }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(layoutJSON.utf8))
    let written: Written = try await client.call("doc.set", Set(name: HerdrAppLayout.documentName, value: value, version: current.version))

    for try await message in subscription.messages {
        if case .event(let event) = message, case .doc(let name) = event.change, name == HerdrAppLayout.documentName { break }
    }
    let layout = try #require(try await client.herdrAppLayout())
    #expect(layout.spaces.map(\.name) == ["", "herdr ios", "empty"])
    #expect(written.version > current.version)

    struct Empty: Codable, Sendable {}
    let _: Empty? = try? await client.call("server.stop", Empty())
    await client.close()
}
#endif

/// herdr-app's ids are `sp` + 32 lowercase hex digits (see the layout document).
@Test func newSpaceIDsLookLikeHerdrApps() {
    let id = HerdrAppLayout.newSpaceID()
    #expect(id.count == 34)
    #expect(id.hasPrefix("sp"))
    #expect(id.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(HerdrAppLayout.newSpaceID() != id)
}

@Test func terminalNamesFollowHerdrCoreRules() {
    for good in ["review", "web", "test", "t", "tab2", "a.b_c-1", "1st", "taa"] {
        #expect(HerdrCore.isValidTerminalName(good), "\(good)")
    }
    for bad in ["", "Review", "-x", "has space", "t7", "t2c", "t10", String(repeating: "a", count: 33), "ünï"] {
        #expect(!HerdrCore.isValidTerminalName(bad), "\(bad)")
    }
}

#if os(macOS)
/// Start a shell and a command, see templates, kill and remove, against a real core.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: localCore.path)), .timeLimit(.minutes(1)))
func localHerdrCoreRunKillRemove() async throws {
    let client = try await HerdrClient.connect(
        over: try ProcessTransport(executable: localCore, environment: ["HC_SESSION": "herdrkit-test-run"]))
    _ = try await client.templates()  // whatever this machine has; must decode

    let shell = try await client.run(RunRequest(cwd: "/tmp", name: "herdrkit-shell", labels: ["herdr.space": "sp1"], keep: true))
    #expect(shell.isLive)
    #expect(shell.labels["herdr.space"] == "sp1")
    #expect(shell.name == "herdrkit-shell")

    let job = try await client.run(RunRequest(line: "exit 4"))
    try await client.kill(shell.address)
    // Wait until both have finished, then remove them.
    for _ in 0..<50 {
        let all = try await client.listTerminals(all: true).terminals
        if all.filter({ [shell.address, job.address].contains($0.address) }).allSatisfy({ !$0.isLive }) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    try await client.remove(shell.address)
    try await client.remove(job.address)
    let left = try await client.listTerminals(all: true).terminals.map(\.address)
    #expect(!left.contains(shell.address) && !left.contains(job.address))

    struct Empty: Codable, Sendable {}
    let _: Empty? = try? await client.call("server.stop", Empty())
    await client.close()
}
#endif
