import CryptoKit
import Foundation
import LocalAuthentication
import Security

final class KeychainStore: Sendable {
    // Separate from the legacy page-key service; never modify legacy entries.
    private let service = "dev.ryandetzel.tinystash.portable-vault.encryption"
    private let keyByteCount = 32

    func remember(_ key: SymmetricKey, id: UUID) throws {
        guard key.bitCount == keyByteCount * 8 else {
            throw KeychainError.invalidKeyData
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            let detail = accessError.map { ($0.takeRetainedValue() as Error).localizedDescription }
            throw KeychainError.accessControlUnavailable(detail)
        }

        var query = identityQuery(id: id)
        query[kSecAttrAccessControl] = accessControl
        query[kSecValueData] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(query as CFDictionary, nil)
        // Duplicates may hold a different key. Never update or replace them.
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    private func identityQuery(id: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    func unlock(id: UUID, context: LAContext) throws -> SymmetricKey {
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var query = identityQuery(id: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
        guard let bytes = result as? Data, bytes.count == keyByteCount else {
            throw KeychainError.invalidKeyData
        }
        return SymmetricKey(data: bytes)
    }
}

private enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    case invalidKeyData
    case accessControlUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .status(errSecItemNotFound):
            return "No remembered key was found for this vault (Keychain status \(errSecItemNotFound)). Open it with its password."
        case .status(errSecDuplicateItem):
            return "A key is already remembered for this vault (Keychain status \(errSecDuplicateItem)). The existing key has not been replaced. You can still open the vault with its password."
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "The vault key is unavailable: \(detail) (Keychain status \(status)). You can still open the vault with its password."
        case .invalidKeyData:
            return "The vault key must contain exactly 256 bits. You can still open the vault with its password."
        case .accessControlUnavailable(let detail):
            let reason = detail.map { " (\($0))" } ?? ""
            return "Keychain user-presence protection is unavailable\(reason). The vault can still be opened with its password."
        }
    }
}
