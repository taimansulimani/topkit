import Foundation
import XCTest
import CryptoKit
#if canImport(TopkitCore)
@testable import TopkitCore
#elseif canImport(Topkit)
@testable import Topkit
#endif

final class ClipboardSecurityTests: XCTestCase {
    func testEncryptDecryptRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("super secret clipboard text 🔐".utf8)

        let ciphertext = try ClipboardCrypto.encrypt(plaintext, key: key)
        // Ciphertext must not equal (or contain) the plaintext bytes.
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertFalse(ciphertext.range(of: plaintext) != nil)

        let decrypted = try ClipboardCrypto.decrypt(ciphertext, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptWithWrongKeyFails() throws {
        let ciphertext = try ClipboardCrypto.encrypt(Data("payload".utf8), key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try ClipboardCrypto.decrypt(ciphertext, key: SymmetricKey(size: .bits256)))
    }

    func testDecryptOrPassthroughDecryptsValidCiphertext() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("hello".utf8)
        let ciphertext = try ClipboardCrypto.encrypt(plaintext, key: key)

        XCTAssertEqual(ClipboardCrypto.decryptOrPassthrough(ciphertext, key: key), plaintext)
    }

    func testDecryptOrPassthroughReturnsLegacyPlaintextUnchanged() {
        let key = SymmetricKey(size: .bits256)
        // Simulates a legacy unencrypted blob (e.g. a raw PNG header / JSON written before
        // encryption existed): it isn't a valid AES-GCM box, so it passes through unchanged.
        let legacy = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        XCTAssertEqual(ClipboardCrypto.decryptOrPassthrough(legacy, key: key), legacy)
    }
}
