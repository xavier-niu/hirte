@preconcurrency import Citadel
import Foundation
import KeyStore
import NIOCore
@preconcurrency import NIOSSH

public enum SSHTransportError: Error, LocalizedError {
    case hostKeyChanged(host: String, expected: String, offered: String)
    case hostKeyRejected(host: String)
    case authenticationFailed(username: String)
    case passwordRejected(username: String)
    case commandFailed(exitCode: Int, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let host, let expected, let offered):
            "The host key of \(host) changed (expected \(expected), got \(offered)). "
                + "This could be an attack, or the server was reinstalled."
        case .hostKeyRejected(let host): "The host key of \(host) was not trusted."
        case .authenticationFailed(let username): "The server did not accept the key for \(username)."
        case .passwordRejected(let username):
            "The server did not accept the password for \(username). "
                + "If it's right, the server may not allow password login: use an SSH key instead."
        case .commandFailed(let code, let stderr):
            stderr.isEmpty ? "The remote command exited with \(code)." : stderr
        }
    }
}

/// How to log in. Passwords only work where the server takes the "password" method: NIOSSH has no
/// "keyboard-interactive", which is all that some servers offer instead.
public enum SSHCredential: Sendable {
    case key(SigningKey)
    case password(String)

    fileprivate func authenticationMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .key(let key):
            let privateKey: NIOSSHPrivateKey =
                switch key {
                case .secureEnclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
                case .software(let key): NIOSSHPrivateKey(p256Key: key)
                }
            return .custom(PublicKeyAuthentication(username: username, key: privateKey))
        case .password(let password):
            return .passwordBased(username: username, password: password)
        }
    }

    /// The error for a server saying no to this.
    func rejected(username: String) -> SSHTransportError {
        switch self {
        case .key: .authenticationFailed(username: username)
        case .password: .passwordRejected(username: username)
        }
    }
}

/// An authenticated SSH connection.
public final class SSHConnection: @unchecked Sendable {
    private let client: SSHClient
    public let target: SSHTarget

    private init(client: SSHClient, target: SSHTarget) {
        self.client = client
        self.target = target
    }

    /// Connects and logs in. The host key comes first: a password only ever goes to a server
    /// that passed `knownHosts` or `onUnknownHost`.
    public static func connect(
        to target: SSHTarget,
        credential: SSHCredential,
        knownHosts: any KnownHostsStore,
        onUnknownHost: @escaping UnknownHostHandler,
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SSHConnection {
        do {
            let client = try await SSHClient.connect(
                host: target.host,
                port: target.port,
                authenticationMethod: credential.authenticationMethod(username: target.username),
                hostKeyValidator: .custom(TOFUHostKeyValidator(
                    host: target.knownHostsName, store: knownHosts, onUnknownHost: onUnknownHost)),
                reconnect: .never,
                connectTimeout: timeout)
            return SSHConnection(client: client, target: target)
        } catch SSHClientError.allAuthenticationOptionsFailed {
            // What a "no" from the server turns into: Citadel (0.12.1) asks its authentication
            // method for one offer and fails by itself when asked for another.
            throw credential.rejected(username: target.username)
        }
    }

    public var isConnected: Bool { client.isConnected }

    /// Runs a command and returns its stdout.
    public func run(_ command: String) async throws -> String {
        let output = try await client.executeCommand(command)
        return String(buffer: output)
    }

    /// Starts a long-lived command (no PTY) and gives raw access to its stdin and stdout.
    public func openExec(_ command: String) async throws -> ExecPipe {
        try await ExecPipe.open(command: command, on: client)
    }

    public func close() async {
        try? await client.close()
    }
}

/// Offers one public key, once.
final class PublicKeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed(username: username))
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}
