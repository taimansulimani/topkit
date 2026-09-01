import Foundation
import CryptoKit
import Security

/// AES-GCM encryption for clipboard data at rest (history blob + persisted images).
///
/// Pure and testable: the caller supplies the key. The app uses `ClipboardKeyStore`'s
/// Keychain-backed key; tests can pass an in-memory key.
enum ClipboardCrypto {
    enum CryptoError: Error { case sealFailed }

    /// Encrypts `plaintext` with AES-GCM, returning the combined (nonce‖ciphertext‖tag) blob.
    /// AES-GCM uses hardware AES, so even multi-MB images encrypt in well under a millisecond.
    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.sealFailed }
        return combined
    }

    /// Decrypts a combined AES-GCM blob produced by `encrypt(_:key:)`.
    static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    /// Decrypts if `data` is a valid AES-GCM blob for `key`; otherwise returns `data`
    /// unchanged. This lets us transparently read legacy plaintext written before
    /// encryption existed and re-encrypt it on the next write — no version flag or
    /// separate migration pass required.
    static func decryptOrPassthrough(_ data: Data, key: SymmetricKey) -> Data {
        (try? decrypt(data, key: key)) ?? data
    }
}

/// Provides (and lazily creates) the 256-bit symmetric key used to encrypt clipboard data
/// at rest. The key lives in the Keychain, scoped to this device and never synced to iCloud,
/// so the on-disk clipboard history/images are useless without it.
enum ClipboardKeyStore {
    private static let service = "com.topkit.app.clipboard"
    private static let account = "history-encryption-key-v1"

    private static let lock = NSLock()
    /// Cached so save/load don't hit the Keychain repeatedly.
    private static var cachedKey: SymmetricKey?

    /// Returns the persistent encryption key, creating and storing one on first use.
    /// If the Keychain is unavailable (e.g. a locked headless CI keychain), falls back to
    /// an ephemeral process-lifetime key so the app/tests still function.
    static func key() -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let resolved = loadKey() ?? createAndStoreKey()
        cachedKey = resolved
        return resolved
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func loadKey() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    private static func createAndStoreKey() -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Clear any stale/partial item first so the add can't fail with errSecDuplicateItem.
        SecItemDelete(baseQuery() as CFDictionary)

        var attributes = baseQuery()
        attributes[kSecValueData as String] = keyData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Best-effort: if the store fails (locked keychain), we still return the in-memory key.
        SecItemAdd(attributes as CFDictionary, nil)
        return key
    }
}
