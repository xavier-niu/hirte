@preconcurrency import Citadel
import CryptoKit
import NIOCore
@preconcurrency import NIOSSH
import Testing
@testable import SSHTransport

/// A server that takes any password and whose commands are numbers: the exit code they end with
/// right away. Like OpenSSH, it closes the channel itself after a command ends.
private final class ExitingCommands: NIOSSHServerUserAuthenticationDelegate, ExecDelegate {
    private struct Running: ExecCommandContext {
        func terminate() async throws {}
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
    }

    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        outputHandler.succeed(exitCode: Int(command) ?? 1)
        return Running()
    }

    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}
}

private func withServer(_ body: (SSHClient) async throws -> Void) async throws {
    // SSHServer doesn't publicly say which port it got, so this can't ask for any free one.
    let port = Int.random(in: 49_152...65_535)
    let commands = ExitingCommands()
    let server = try await SSHServer.host(
        host: "127.0.0.1",
        port: port,
        hostKeys: [NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())],
        authenticationDelegate: commands)
    server.enableExec(withDelegate: commands)
    let client = try await SSHClient.connect(
        host: "127.0.0.1",
        port: port,
        authenticationMethod: .passwordBased(username: "me", password: "any"),
        hostKeyValidator: .acceptAnything(),
        reconnect: .never)
    try await body(client)
    try? await client.close()
    try? await server.close()
}

/// `withExec` throwing `alreadyClosed` used to hide this: a machine without herdr-core said
/// "NIOCore.ChannelError error 6" instead of that it isn't installed.
@Test(.timeLimit(.minutes(1))) func aFailedCommandSaysHowItEnded() async throws {
    try await withServer { client in
        let pipe = try await ExecPipe.open(command: "127", on: client)
        do {
            for try await _ in pipe.output {}
            Issue.record("The exit code was not reported.")
        } catch SSHTransportError.commandFailed(let exitCode, _) {
            #expect(exitCode == 127)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func aCommandThatSucceedsJustEndsItsOutput() async throws {
    try await withServer { client in
        let pipe = try await ExecPipe.open(command: "0", on: client)
        for try await _ in pipe.output {}
    }
}
