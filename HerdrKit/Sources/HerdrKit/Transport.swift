import Foundation
import SSHTransport

/// A byte pipe to `herdr-core connect`.
public protocol ByteTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func close()
}

extension ExecPipe: ByteTransport {
    public var incoming: AsyncThrowingStream<Data, Error> { output }
    public func send(_ data: Data) async throws { try await write(data) }
}

public enum HerdrCore {
    /// The protocol generation this client speaks.
    public static let generation = 1

    /// Shell line that connects stdin/stdout to the core on an SSH host. Same as
    /// herdr-core's own `hc machine add` (see `machines.rs`, `fn pipe`): find
    /// `herdr-core` on PATH or in `~/.local/bin`, then `exec herdr-core connect`.
    public static func connectCommand(session: String? = nil) -> String {
        let sessionPrefix = session.map { "HC_SESSION=\(shellQuoteInner($0)) " } ?? ""
        return "sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; "
            + "[ -x \"$p\" ] || { echo \"\(notInstalledMessage)\" >&2; exit 127; }; "
            + "\(sessionPrefix)exec \"$p\" connect'"
    }

    public static let notInstalledMessage = "herdr-core is not installed here"

    /// Whether `connectCommand` failed because the machine has no herdr-core, and not because one
    /// that's there couldn't start, which installing wouldn't fix.
    public static func isNotInstalled(_ error: Error) -> Bool {
        guard case SSHTransportError.commandFailed(127, let stderr) = error else { return false }
        return stderr.contains(notInstalledMessage)
    }

    /// herdr-core's official installer. It needs no root, and puts herdr-core in `~/.local/bin`,
    /// where `connectCommand` looks.
    public static let installerURL = "https://releases.herdr.dev/core/install.sh"

    /// Shell line that runs the installer. Its documented `curl … | sh` succeeds when the download
    /// fails, since `sh` then has nothing to run, and could run half a script. So this downloads it
    /// first. It exits with 0 or 1: a 127 from the installer would read as "not installed".
    public static var installCommand: String {
        "sh -c 's=$(curl -fsSL \(installerURL)) || { echo \"could not download \(installerURL)\" >&2; exit 1; }; "
            + "printf \"%s\\n\" \"$s\" | sh || exit 1'"
    }

    /// Installs herdr-core on that machine, and returns once the installer is done. That runs code
    /// from the internet there, so only do this after asking.
    public static func install(on ssh: SSHConnection) async throws {
        let pipe = try await ssh.openExec(installCommand)
        defer { pipe.close() }
        do {
            for try await _ in pipe.output {}
        } catch SSHTransportError.commandFailed(_, let stderr) {
            throw HerdrError.installFailed(stderr)
        }
    }

    /// Session names are restricted by herdr-core, but stay safe inside the outer single quotes anyway.
    private static func shellQuoteInner(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

#if os(macOS)
/// Runs `herdr-core connect` locally. For tests and a future macOS build.
public final class ProcessTransport: ByteTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>
    private let process: Process
    private let stdin: FileHandle

    public init(executable: URL, arguments: [String] = ["connect"], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        try process.run()
        self.process = process
        self.stdin = input.fileHandleForWriting
        self.incoming = stream
    }

    public func send(_ data: Data) async throws {
        try stdin.write(contentsOf: data)
    }

    public func close() {
        try? stdin.close()
        if process.isRunning { process.terminate() }
    }
}
#endif
