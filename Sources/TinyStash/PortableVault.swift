import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Version 1 stores big-endian integers followed by fixed-size cryptographic fields:
/// magic (8), version (2), KDF (2), rounds (4), salt length (2), wrapped-key
/// length (2), UUID (16), salt (32), wrapped AES-GCM key (60), and content
/// AES-GCM box (at least 28). Both boxes use fresh 12-byte nonces and 16-byte tags.
/// The key wrap authenticates metadata; content authenticates the entire header.
struct PortableVault: Sendable {
    let id: UUID

    private static let magic = Data("TINYSTSH".utf8)
    private static let rounds: UInt32 = 600_000
    private static let metadataSize = 68
    private static let headerSize = 128
    private static let minimumSize = headerSize + 28

    private let header: Data

    private init(id: UUID, header: Data) {
        self.id = id
        self.header = header
    }

    static func create(password: String) throws -> (vault: PortableVault, key: SymmetricKey) {
        let id = UUID()
        let salt = try randomBytes(count: 32)
        var metadata = magic
        append(UInt16(1), to: &metadata) // Envelope version.
        append(UInt16(1), to: &metadata) // PBKDF2-HMAC-SHA256.
        append(rounds, to: &metadata)
        append(UInt16(32), to: &metadata)
        append(UInt16(60), to: &metadata)
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { metadata.append(contentsOf: $0) }
        metadata.append(salt)

        let wrappingKey = try deriveKey(password: password, salt: salt)
        let key = SymmetricKey(size: .bits256)
        var keyData = key.withUnsafeBytes { Data($0) }
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        let box = try AES.GCM.seal(keyData, using: wrappingKey, authenticating: metadata)
        guard let wrappedKey = box.combined, wrappedKey.count == 60 else {
            throw PortableVaultError.invalidEnvelope
        }
        metadata.append(wrappedKey)
        return (PortableVault(id: id, header: metadata), key)
    }

    init(data: Data) throws {
        // Validate the complete fixed-size header before any password derivation.
        // Index relative to startIndex so callers may also pass a Data slice.
        guard data.count >= Self.minimumSize else { throw PortableVaultError.invalidEnvelope }
        let header = Data(data.prefix(Self.headerSize))
        guard header.prefix(8) == Self.magic else { throw PortableVaultError.invalidEnvelope }
        guard Self.integer(header, at: 8, count: 2) == 1 else {
            throw PortableVaultError.unsupportedVersion
        }
        guard Self.integer(header, at: 10, count: 2) == 1,
              Self.integer(header, at: 12, count: 4) == Self.rounds,
              Self.integer(header, at: 16, count: 2) == 32,
              Self.integer(header, at: 18, count: 2) == 60 else {
            throw PortableVaultError.invalidEnvelope
        }
        id = UUID(uuid: (
            header[20], header[21], header[22], header[23],
            header[24], header[25], header[26], header[27],
            header[28], header[29], header[30], header[31],
            header[32], header[33], header[34], header[35]
        ))
        self.header = header
    }

    func unlock(password: String) throws -> SymmetricKey {
        let wrappingKey = try Self.deriveKey(password: password, salt: Data(header[36..<68]))
        var keyData: Data
        do {
            let box = try AES.GCM.SealedBox(combined: header[Self.metadataSize..<Self.headerSize])
            keyData = try AES.GCM.open(box, using: wrappingKey, authenticating: header.prefix(Self.metadataSize))
        } catch {
            throw PortableVaultError.authenticationFailed
        }
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        guard keyData.count == 32 else { throw PortableVaultError.invalidEnvelope }
        return SymmetricKey(data: keyData)
    }

    func seal(_ text: String, using key: SymmetricKey) throws -> Data {
        guard key.bitCount == 256 else { throw PortableVaultError.invalidKey }
        let box = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: header)
        guard let combined = box.combined else { throw PortableVaultError.invalidEnvelope }
        var data = header
        data.append(combined)
        return data
    }

    func load(_ data: Data, using key: SymmetricKey) throws -> String {
        guard key.bitCount == 256 else { throw PortableVaultError.invalidKey }
        guard data.count >= Self.minimumSize,
              data.prefix(Self.headerSize) == header else {
            throw PortableVaultError.invalidEnvelope
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.headerSize))
            plaintext = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw PortableVaultError.authenticationFailed
        }
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw PortableVaultError.invalidText
        }
        return text
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var passwordData = Data(password.utf8)
        // Keep a non-null C buffer even for an empty password; the trailing
        // byte is excluded from the explicit length (embedded NULs still count).
        passwordData.append(0)
        defer { passwordData.resetBytes(in: 0..<passwordData.count) }
        var derived = Data(count: 32)
        defer { derived.resetBytes(in: 0..<derived.count) }
        let status = derived.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            passwordData.withUnsafeBytes { (passwordBytes: UnsafeRawBufferPointer) in
                salt.withUnsafeBytes { (saltBytes: UnsafeRawBufferPointer) in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordBytes.count - 1,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw PortableVaultError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw PortableVaultError.randomGenerationFailed }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func integer(_ data: Data, at offset: Int, count: Int) -> UInt32 {
        data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

enum PortableVaultError: LocalizedError {
    case invalidEnvelope
    case unsupportedVersion
    case invalidKey
    case invalidText
    case keyDerivationFailed
    case randomGenerationFailed
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            "This is not a valid portable Tiny Stash note, or the file is damaged. Legacy notes require their original key. The file has not been modified."
        case .unsupportedVersion:
            "This note uses an unsupported Tiny Stash file version. Legacy notes require their original key. The file has not been modified."
        case .authenticationFailed:
            "The password is incorrect, or this note is damaged."
        case .invalidKey:
            "This note could not be opened with the available encryption key."
        case .invalidText:
            "This note contains invalid text and cannot be opened."
        case .keyDerivationFailed:
            "Tiny Stash could not derive the encryption key from the password."
        case .randomGenerationFailed:
            "Tiny Stash could not obtain secure random data to create the note."
        }
    }
}
