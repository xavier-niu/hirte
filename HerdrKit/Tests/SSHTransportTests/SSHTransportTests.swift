import CryptoKit
import Foundation
import KeyStore
import Testing
@testable import SSHTransport

@Test func authorizedKeysLineParsesInNIOSSH() {
    let key = P256.Signing.PrivateKey().publicKey
    let line = OpenSSH.authorizedKeysLine(key, comment: "phone")
    let parts = line.split(separator: " ")
    #expect(normalizedOpenSSHPublicKey(line) == "\(parts[0]) \(parts[1])")
}

@Test func aRejectionNamesWhatWasRejected() throws {
    let key = try #require(SSHCredential.key(.software(P256.Signing.PrivateKey())).rejected(username: "me").errorDescription)
    #expect(key.contains("key for me"))
    let password = try #require(SSHCredential.password("correct horse").rejected(username: "me").errorDescription)
    #expect(password.contains("password for me"))
    #expect(!password.contains("correct horse"))
}

@Test func knownHostsNames() {
    #expect(SSHTarget(host: "box", username: "me").knownHostsName == "box")
    #expect(SSHTarget(host: "box", port: 2222, username: "me").knownHostsName == "[box]:2222")
}

@Test func inMemoryKnownHosts() {
    let hosts = InMemoryKnownHosts()
    #expect(hosts.hostKey(for: "box") == nil)
    hosts.setHostKey("ssh-ed25519 AAAA", for: "box")
    #expect(hosts.hostKey(for: "box") == "ssh-ed25519 AAAA")
    hosts.removeHostKey(for: "box")
    #expect(hosts.hostKey(for: "box") == nil)
}
