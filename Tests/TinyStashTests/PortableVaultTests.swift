import CryptoKit
import Foundation
import XCTest
@testable import TinyStash

final class PortableVaultTests: XCTestCase {
    private let fixturePassword = "portable fixture password\0 café"
    private let headerSize = 128

    /// An independently specified v1 envelope with fixed salt, key and nonces.
    /// The wrapping key is Python hashlib.pbkdf2_hmac("sha256", password.utf8,
    /// bytes(range(32)), 600000, 32), not derived by the implementation under test.
    private func fixture(plaintext: Data = Data("Fixture secret\nΕλληνικά\0".utf8)) throws -> (
        vault: PortableVault, data: Data, key: SymmetricKey
    ) {
        var metadata = Data([
            0x54, 0x49, 0x4e, 0x59, 0x53, 0x54, 0x53, 0x48,
            0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x27, 0xc0,
            0x00, 0x20, 0x00, 0x3c
        ])
        metadata.append(contentsOf: UInt8(16)...UInt8(31))
        metadata.append(contentsOf: UInt8(0)...UInt8(31))
        let wrappingKey = SymmetricKey(data: Data([
            0x13, 0x2e, 0x3b, 0x56, 0xce, 0x4c, 0x61, 0xff,
            0xb1, 0xe8, 0x7f, 0x2e, 0x3a, 0x23, 0x67, 0xe1,
            0x7a, 0x42, 0xb4, 0x1e, 0xcf, 0xf6, 0x2d, 0x01,
            0xbc, 0x2a, 0xe2, 0x39, 0x63, 0xdb, 0xee, 0x46
        ]))
        let keyData = Data(repeating: 0x31, count: 32)
        let key = SymmetricKey(data: keyData)
        let wrapped = try AES.GCM.seal(
            keyData, using: wrappingKey,
            nonce: AES.GCM.Nonce(data: Data(repeating: 0x41, count: 12)),
            authenticating: metadata
        )
        var data = metadata
        data.append(try XCTUnwrap(wrapped.combined))
        let content = try AES.GCM.seal(
            plaintext, using: key,
            nonce: AES.GCM.Nonce(data: Data(repeating: 0x52, count: 12)),
            authenticating: data
        )
        data.append(try XCTUnwrap(content.combined))
        return (try PortableVault(data: data), data, key)
    }

    func testDeterministicVersionOneFixtureUnlocks() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.vault.id.uuidString, "10111213-1415-1617-1819-1A1B1C1D1E1F")
        let key = try fixture.vault.unlock(password: fixturePassword)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, fixture.key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try fixture.vault.load(fixture.data, using: key), "Fixture secret\nΕλληνικά\0")
    }

    func testPasswordRoundTripAfterMovingAndRenamingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.tinystash")
        let destination = directory.appendingPathComponent("moved", isDirectory: true)
            .appendingPathComponent("renamed.tinystash")
        let password = "A portable password 🔐 café"
        let created = try PortableVault.create(password: password)
        let text = "Fake secret\nCafé Ελληνικά\0\n"
        let sealed = try created.vault.seal(text, using: created.key)
        try EncryptedStore(url: source).saveSealed(sealed, createOnly: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)

        let bytes = try Data(contentsOf: destination)
        let reopened = try PortableVault(data: bytes)
        XCTAssertEqual(reopened.id, created.vault.id)
        let key = try reopened.unlock(password: password)
        XCTAssertEqual(try reopened.load(bytes, using: key), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(bytes.range(of: Data(text.utf8)))
        XCTAssertNil(bytes.range(of: Data(password.utf8)))
    }

    func testWrongPasswordIsRejected() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.vault.unlock(password: "wrong password"))
    }

    func testMetadataAndWrappedKeyTamperingIsAuthenticated() throws {
        let fixture = try fixture()
        // UUID, salt, wrapping nonce, wrapped content key, wrapping tag.
        for offset in [20, 36, 68, 80, 127] {
            var tampered = fixture.data
            tampered[offset] ^= 1
            let parsed = try PortableVault(data: tampered)
            XCTAssertThrowsError(try parsed.unlock(password: fixturePassword), "offset \(offset)")
            // Even an already-unlocked content key cannot accept changed metadata.
            XCTAssertThrowsError(try parsed.load(tampered, using: fixture.key), "offset \(offset)")
        }
    }

    func testContentNonceCiphertextAndTagTamperingIsRejected() throws {
        let fixture = try fixture()
        for offset in [headerSize, headerSize + 12, fixture.data.count - 1] {
            var tampered = fixture.data
            tampered[offset] ^= 1
            let parsed = try PortableVault(data: tampered)
            XCTAssertThrowsError(try parsed.load(tampered, using: fixture.key), "offset \(offset)")
        }
        var appended = fixture.data
        appended.append(0)
        XCTAssertThrowsError(try fixture.vault.load(appended, using: fixture.key))
        XCTAssertThrowsError(try fixture.vault.load(Data(fixture.data.dropLast()), using: fixture.key))
    }

    func testMalformedHeadersAreRejectedBeforeUnlock() throws {
        let fixture = try fixture()
        for length in 0..<(headerSize + 28) {
            XCTAssertThrowsError(try PortableVault(data: Data(fixture.data.prefix(length))), "length \(length)")
        }
        // Magic, both version bytes, KDF identifier, each rounds byte, and lengths.
        for offset in [0, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19] {
            var malformed = fixture.data
            malformed[offset] ^= 0xff
            XCTAssertThrowsError(try PortableVault(data: malformed), "offset \(offset)")
        }
        var excessiveRounds = fixture.data
        excessiveRounds.replaceSubrange(12..<16, with: [0xff, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try PortableVault(data: excessiveRounds))
    }


    func testSamePasswordCreatesIndependentFiles() throws {
        let password = "Same password for independent files"
        let first = try PortableVault.create(password: password)
        let second = try PortableVault.create(password: password)
        let firstData = try first.vault.seal("First fake secret", using: first.key)
        let secondData = try second.vault.seal("Second fake secret", using: second.key)
        XCTAssertNotEqual(first.vault.id, second.vault.id)
        XCTAssertNotEqual(firstData[36..<68], secondData[36..<68])
        XCTAssertNotEqual(firstData[68..<128], secondData[68..<128])
        XCTAssertNotEqual(first.key.withUnsafeBytes { Data($0) }, second.key.withUnsafeBytes { Data($0) })

        for (data, expected) in [(firstData, "First fake secret"), (secondData, "Second fake secret")] {
            let reopened = try PortableVault(data: data)
            let key = try reopened.unlock(password: password)
            XCTAssertEqual(try reopened.load(data, using: key), expected)
        }
        XCTAssertThrowsError(try first.vault.load(firstData, using: second.key))
        XCTAssertThrowsError(try second.vault.load(secondData, using: first.key))
        XCTAssertThrowsError(try first.vault.load(secondData, using: second.key))
    }

    func testEverySealUsesFreshContentNonceIncludingEmptyText() throws {
        let fixture = try fixture()
        for text in ["Repeated fake secret", ""] {
            let first = try fixture.vault.seal(text, using: fixture.key)
            let second = try fixture.vault.seal(text, using: fixture.key)
            XCTAssertEqual(first.prefix(headerSize), second.prefix(headerSize))
            XCTAssertNotEqual(first[headerSize..<(headerSize + 12)], second[headerSize..<(headerSize + 12)])
            XCTAssertNotEqual(first, second)
            for data in [first, second] {
                let reopened = try PortableVault(data: data)
                XCTAssertEqual(try reopened.load(data, using: fixture.key), text)
            }
        }
    }

    func testAuthenticatedNonUTF8ContentIsRejected() throws {
        let fixture = try fixture(plaintext: Data([0xff]))
        XCTAssertThrowsError(try fixture.vault.load(fixture.data, using: fixture.key))
    }

    func testNon256BitContentKeyIsRejected() throws {
        let fixture = try fixture()
        let shortKey = SymmetricKey(data: Data(repeating: 0x31, count: 16))
        XCTAssertThrowsError(try fixture.vault.seal("Fake secret", using: shortKey))
        XCTAssertThrowsError(try fixture.vault.load(fixture.data, using: shortKey))
    }
}
