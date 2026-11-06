import Foundation
import SSHTransport

public enum HerdrError: Error, LocalizedError {
    /// A JSON-RPC error from the core. `kind` is stable (`not_found`, `needs_framed`, ...).
    case rpc(code: Int, message: String, kind: String?, hint: String?)
    case connectionClosed
    case invalidResponse(String)
    /// The installer's own message, or nothing if it gave none.
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rpc(_, let message, _, let hint): [message, hint].compactMap { $0 }.joined(separator: "\n")
        case .connectionClosed: "The connection to herdr-core closed."
        case .invalidResponse(let detail): "Unexpected answer from herdr-core: \(detail)"
        case .installFailed(let reason):
            reason.isEmpty ? "Could not install herdr-core." : "Could not install herdr-core: \(reason)"
        }
    }
}

/// A connection to one herdr-core in framed mode: JSON-RPC on channel 0,
/// event and terminal streams on their own channels.
public actor HerdrClient {
    private let transport: any ByteTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closedError: Error?

    /// The first message goes out as a plain line; after the `hello` reply both sides use frames.
    private var framed = false
    private var helloID: Int?
    private var input = FrameReader()

    private var channels: [UInt32: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    /// Stream bytes that arrived before their channel was claimed (the subscribe reply races its first data).
    private var early: [UInt32: [Frame]] = [:]
    /// Channels we closed: what the core still sends on them until its CLOSE is dropped.
    private var closedChannels: Set<UInt32> = []

    /// The core's answer to `hello`.
    public private(set) var hello: HelloResult?

    init(transport: any ByteTransport) {
        self.transport = transport
    }

    /// Starts reading and performs the `hello` handshake, switching to framed mode.
    public static func connect(over transport: any ByteTransport) async throws -> HerdrClient {
        let client = HerdrClient(transport: transport)
        await client.startReading()
        do {
            try await client.handshake()
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    /// Opens `herdr-core connect` over SSH and connects to it.
    public static func connect(ssh: SSHConnection, session: String? = nil) async throws -> HerdrClient {
        let pipe = try await ssh.openExec(HerdrCore.connectCommand(session: session))
        return try await connect(over: pipe)
    }

    public func close() {
        reader?.cancel()
        transport.close()
        fail(HerdrError.connectionClosed)
    }

    // MARK: Methods

    public func listTerminals(all: Bool = false) async throws -> TerminalList {
        try await call("terminal.list", ListParams(all: all))
    }

    /// Reads an opaque document stored in the core (`doc.get`). Unwritten names return nil.
    public func document(named name: String, on machine: String? = nil) async throws -> (value: JSONValue?, version: UInt64) {
        let result: DocGetResult = try await call("doc.get", DocGetParams(name: name, on: machine))
        if case .null = result.value { return (nil, result.version) }
        return (result.value, result.version)
    }

    /// herdr-app's spaces and tabs on this core, if herdr-app has written them.
    public func herdrAppLayout() async throws -> HerdrAppLayout? {
        try await document(named: HerdrAppLayout.documentName).value.map(HerdrAppLayout.init(document:))
    }

    /// Subscribes to terminal events: a snapshot, then every change after it.
    /// Cancel iteration of `messages` (or drop it) to unsubscribe.
    public func subscribeEvents() async throws -> EventSubscription {
        let result: SubscribeResult = try await call("events.subscribe", EmptyParams())
        guard let channel = result.channel else {
            throw HerdrError.invalidResponse("events.subscribe returned no channel in framed mode")
        }
        let bytes = openChannel(channel)
        let (messages, continuation) = AsyncThrowingStream<EventMessage, Error>.makeStream()
        let pump = Task {
            var lines = LineSplitter()
            do {
                for try await chunk in bytes {
                    for line in lines.feed(chunk) {
                        if let message = EventMessage.decode(line) { continuation.yield(message) }
                    }
                    try await self.sendFrame(.credit(channel: channel, bytes: chunk.count))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
            Task { await self.closeChannel(channel) }
        }
        return EventSubscription(seq: result.seq, terminals: result.terminals, messages: messages)
    }

    /// Attaches to a live terminal: first its current screen, then its output as it happens.
    /// The last active viewer sets the terminal's size, so attaching at `cols`×`rows` resizes it
    /// unless `observe` is set.
    public func attach(
        terminal address: String, cols: Int, rows: Int,
        history: Int = 0, observe: Bool = false, display: DisplayFacts? = nil
    ) async throws -> AttachedTerminal {
        let result: AttachResult = try await call("terminal.attach", AttachParams(
            terminal: address, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
            history: history, observe: observe, display: display))
        let channel = result.channel
        let bytes = openChannel(channel)
        let (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pump = Task {
            do {
                for try await chunk in bytes {
                    continuation.yield(chunk)
                    try await self.sendFrame(.credit(channel: channel, bytes: chunk.count))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
            Task { await self.closeChannel(channel) }
        }
        // Both sides must support it: an old core drops frame kinds it doesn't know.
        let automaticInput = result.automaticInput == true && hello?.features.contains("automatic_input") == true
        return AttachedTerminal(
            terminal: result.terminal, channel: channel, output: output, automaticInput: automaticInput, client: self)
    }

    /// Calls any method by name.
    public func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, _ params: Params
    ) async throws -> Result {
        let id = nextID
        nextID += 1
        let message = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        if method == "hello" { helloID = id }
        // Hello is the one plain line; everything after it is a frame on channel 0.
        let wire = framed ? Frame(channel: 0, kind: .data, payload: message).encoded() : message + Data([0x0A])

        let response: Data = try await withCheckedThrowingContinuation { continuation in
            if let closedError {
                continuation.resume(throwing: closedError)
                return
            }
            pending[id] = continuation
            Task { await self.send(wire, id: id) }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: response)
        if let error = envelope.error {
            throw HerdrError.rpc(code: error.code, message: error.message, kind: error.data?.kind, hint: error.data?.hint)
        }
        do {
            return try JSONDecoder().decode(ResultEnvelope<Result>.self, from: response).result
        } catch {
            throw HerdrError.invalidResponse("\(method): \(error)")
        }
    }

    // MARK: Channels

    /// Claims a stream channel the core announced. Bytes arrive in order; the stream ends on CLOSE.
    func openChannel(_ channel: UInt32) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        if let closedError {
            continuation.finish(throwing: closedError)
            return stream
        }
        channels[channel] = continuation
        for frame in early.removeValue(forKey: channel) ?? [] { route(frame) }
        return stream
    }

    func closeChannel(_ channel: UInt32) async {
        guard channels.removeValue(forKey: channel) != nil else { return }
        closedChannels.insert(channel)
        try? await sendFrame(Frame(channel: channel, kind: .close))
    }

    func sendFrame(_ frame: Frame) async throws {
        try await transport.send(frame.encoded())
    }

    // MARK: Plumbing

    private func handshake() async throws {
        hello = try await call("hello", HelloParams(generation: HerdrCore.generation, framed: true))
        guard hello?.framed == true else {
            throw HerdrError.invalidResponse("the core did not switch to framed mode")
        }
    }

    private func send(_ data: Data, id: Int) async {
        do {
            try await transport.send(data)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func startReading() {
        let incoming = transport.incoming
        reader = Task { [weak self] in
            do {
                for try await chunk in incoming {
                    try await self?.ingest(chunk)
                }
                await self?.fail(HerdrError.connectionClosed)
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func ingest(_ chunk: Data) throws {
        input.append(chunk)
        while true {
            if !framed {
                guard let line = input.nextLine() else { return }
                if !line.isEmpty { handleControl(line) }
            } else {
                guard let frame = try input.nextFrame() else { return }
                route(frame)
            }
        }
    }

    private func route(_ frame: Frame) {
        if frame.channel == 0 {
            if frame.kind == Frame.Kind.data.rawValue { handleControl(frame.payload) }
            return
        }
        guard let continuation = channels[frame.channel] else {
            if closedChannels.contains(frame.channel) {
                if frame.kind == Frame.Kind.close.rawValue { closedChannels.remove(frame.channel) }
                return
            }
            early[frame.channel, default: []].append(frame)
            return
        }
        switch Frame.Kind(rawValue: frame.kind) {
        case .data:
            continuation.yield(frame.payload)
        case .close:
            channels.removeValue(forKey: frame.channel)
            let reason = try? JSONDecoder().decode(StreamEnd.self, from: frame.payload)
            if let reason, reason.reason != nil {
                continuation.finish(throwing: reason)
            } else {
                continuation.finish()
            }
        default:
            break
        }
    }

    private func handleControl(_ message: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: message), let id = envelope.id else {
            return
        }
        // The hello reply is the last plain line: switch before reading further.
        if id == helloID, envelope.error == nil {
            framed = (try? JSONDecoder().decode(ResultEnvelope<FramedFlag>.self, from: message))?.result.framed ?? false
        }
        pending.removeValue(forKey: id)?.resume(returning: message)
    }

    private func fail(_ error: Error) {
        closedError = closedError ?? error
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
        let streams = channels
        channels.removeAll()
        for continuation in streams.values { continuation.finish(throwing: error) }
    }
}

/// A snapshot plus the changes after it. Apply `messages` to a `TerminalSnapshot`.
public struct EventSubscription: Sendable {
    public let seq: UInt64
    public let terminals: [Terminal]
    public let messages: AsyncThrowingStream<EventMessage, Error>

    public var snapshot: TerminalSnapshot { TerminalSnapshot(seq: seq, terminals: terminals) }
}

// MARK: Wire types

private struct Request<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

private struct Envelope: Decodable {
    struct RPCError: Decodable {
        struct Detail: Decodable {
            let kind: String?
            let hint: String?
        }
        let code: Int
        let message: String
        let data: Detail?
    }
    let id: Int?
    let error: RPCError?
}

private struct ResultEnvelope<Result: Decodable>: Decodable {
    let result: Result
}

private struct FramedFlag: Decodable {
    let framed: Bool?
}

struct SubscribeResult: Decodable, Sendable {
    let seq: UInt64
    let terminals: [Terminal]
    let channel: UInt32?
}

/// How a stream ended, as the core reports it in CLOSE (`exited`, `killed`, `lost`, ...).
public struct StreamEnd: Error, Decodable, Sendable, LocalizedError {
    public let reason: String?
    public let exitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case reason
        case exitCode = "exit_code"
    }

    public var errorDescription: String? {
        switch reason {
        case "exited": exitCode.map { "The program exited with \($0)." } ?? "The program exited."
        case "killed": "The terminal was killed."
        case let reason?: "The terminal ended (\(reason))."
        case nil: "The terminal ended."
        }
    }
}

/// A viewer's colors and cell size, so the core can answer programs that ask (OSC 10/11, size reports).
public struct DisplayFacts: Encodable, Sendable {
    public var fg: String?
    public var bg: String?
    public var cursor: String?
    public var cell: [UInt32]?

    public init(fg: String? = nil, bg: String? = nil, cursor: String? = nil, cellWidth: Int? = nil, cellHeight: Int? = nil) {
        self.fg = fg
        self.bg = bg
        self.cursor = cursor
        if let cellWidth, let cellHeight { cell = [UInt32(cellWidth), UInt32(cellHeight)] }
    }
}

/// A live connection to one terminal's screen.
public struct AttachedTerminal: Sendable {
    public let terminal: Terminal
    public let channel: UInt32
    /// The first paint, then the program's raw output. Feed it to a `VirtualTerminal`.
    /// Ends when the viewer detaches; throws `StreamEnd` when the program ends.
    public let output: AsyncThrowingStream<Data, Error>
    /// Whether the core takes `sendAutomatic` input as such (not as typing).
    let automaticInput: Bool
    let client: HerdrClient

    /// Sends typed input (already encoded, e.g. by `VirtualTerminal.encode`).
    public func send(_ input: Data) async throws {
        try await client.sendFrame(Frame(channel: channel, kind: .data, payload: input))
    }

    /// Sends what the emulator answered by itself (`VirtualTerminal.takeReplies()`). It reaches
    /// the program without counting as activity; an observer's is dropped by the core.
    public func sendAutomatic(_ input: Data) async throws {
        try await client.sendFrame(Frame(channel: channel, kind: automaticInput ? .automaticInput : .data, payload: input))
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await client.sendFrame(.resize(channel: channel, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)))
    }

    public func focus(_ focused: Bool) async throws {
        try await client.sendFrame(Frame(channel: channel, kind: .focus, payload: Data([focused ? 1 : 0])))
    }

    public func detach() async {
        await client.closeChannel(channel)
    }
}

struct AttachParams: Encodable, Sendable {
    let terminal: String
    let cols: UInt16
    let rows: UInt16
    let history: Int
    let observe: Bool
    let display: DisplayFacts?
}

struct AttachResult: Decodable, Sendable {
    let channel: UInt32
    let terminal: Terminal
    let automaticInput: Bool?

    enum CodingKeys: String, CodingKey {
        case channel, terminal
        case automaticInput = "automatic_input"
    }
}

struct HelloParams: Encodable, Sendable {
    let generation: Int
    let framed: Bool
}

struct ListParams: Encodable, Sendable {
    let all: Bool
}

struct EmptyParams: Encodable, Sendable {}

struct DocGetParams: Encodable, Sendable {
    let name: String
    let on: String?
}

struct DocGetResult: Decodable, Sendable {
    let value: JSONValue?
    let version: UInt64

    enum CodingKeys: String, CodingKey { case value, version }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        version = try c.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
    }
}
