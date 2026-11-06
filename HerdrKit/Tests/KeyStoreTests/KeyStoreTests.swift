import CryptoKit
import Foundation
import Testing
@testable import KeyStore

@Test func generateListRenameDelete() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateKey(label: "phone")
    #expect(try store.keys().map(\.id) == [info.id])

    try store.rename(id: info.id, to: "iPhone")
    #expect(try store.keys().first?.label == "iPhone")

    let key = try store.signingKey(for: info.id)
    #expect(key.publicKey.x963Representation == info.publicKeyX963)

    try store.deleteKey(id: info.id)
    #expect(try store.keys().isEmpty)
}

@Test func softwareKeySigns() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    // Force the software path so the test runs everywhere.
    let key = P256.Signing.PrivateKey()
    let record = StoredKey(
        info: SSHKeyInfo(id: UUID(), label: "sw", kind: .software, requiresBiometry: false,
                         createdAt: Date(), publicKeyX963: key.publicKey.x963Representation),
        keyData: key.rawRepresentation)
    let storage = InMemoryKeyStorage()
    try storage.save(try JSONEncoder().encode(record), account: record.info.id.uuidString)
    _ = store

    guard case .software(let loaded) = try KeyStore(storage: storage).signingKey(for: record.info.id) else {
        Issue.record("expected a software key")
        return
    }
    let message = Data("hello".utf8)
    #expect(key.publicKey.isValidSignature(try loaded.signature(for: message), for: message))
}

@Test(.enabled(if: KeyStore.isSecureEnclaveAvailable))
func secureEnclaveKeySigns() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateKey(label: "se", allowSoftwareFallback: false)
    #expect(info.kind == .secureEnclave)
    guard case .secureEnclave(let key) = try store.signingKey(for: info.id) else {
        Issue.record("expected a Secure Enclave key")
        return
    }
    let message = Data("hello".utf8)
    #expect(info.publicKey.isValidSignature(try key.signature(for: message), for: message))
}

@Test func passwordsAreKeptPerMachine() throws {
    let store = PasswordStore(storage: InMemoryKeyStorage())
    let (one, other) = (UUID(), UUID())
    #expect(try store.password(for: one) == nil)

    try store.setPassword("pässwörd 🐑", for: one)
    try store.setPassword("second", for: other)
    #expect(try store.password(for: one) == "pässwörd 🐑")
    #expect(try store.password(for: other) == "second")

    try store.setPassword("changed", for: one)
    #expect(try store.password(for: one) == "changed")

    try store.deletePassword(for: one)
    #expect(try store.password(for: one) == nil)
    #expect(try store.password(for: other) == "second")
    try store.deletePassword(for: one)  // already gone: not an error
}

#if os(macOS)
/// Our authorized_keys line and fingerprint must match what ssh-keygen says about it.
@Test func matchesSSHKeygen() throws {
    let info = SSHKeyInfo(id: UUID(), label: "my phone", kind: .software, requiresBiometry: false,
                          createdAt: Date(), publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-\(UUID()).pub")
    try info.authorizedKeysLine.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-l", "-E", "sha256", "-f", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(process.terminationStatus == 0)
    // "256 SHA256:… my phone (ECDSA)"
    #expect(out.hasPrefix("256 \(info.fingerprint) my phone (ECDSA)"), "ssh-keygen said: \(out)")
}
#endif
