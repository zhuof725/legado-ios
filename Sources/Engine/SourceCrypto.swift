import Foundation
import CommonCrypto

/// Hutool-compatible symmetric crypto and digests for book-source scripts.
/// Scope is deliberately limited to what real sources use:
///   AES (128/192/256-bit key) and DES, ECB or CBC, PKCS5/PKCS7 padding or NoPadding,
///   MD5/SHA-1/SHA-256/SHA-384/SHA-512 digests and HMAC, hex/base64 byte helpers.
/// Anything else throws; nothing is silently downgraded.
///
/// Differences from Hutool/Kotlin worth knowing:
///  - PKCS5 and PKCS7 are treated as the same padding (Hutool/JCE behave the same
///    for AES; DES uses an 8-byte block, which CommonCrypto's PKCS7 also handles).
///  - Hutool's `decrypt(String)` treats input as hex when every character is a hex
///    digit and the length is even, otherwise as base64. Implemented the same way.
///  - Failed decryption (bad key/padding/length) throws instead of returning garbage.
///  - Values are never logged.
enum SourceCrypto {
    enum CryptoError: Error, Equatable {
        case unsupportedTransformation
        case invalidKeyLength
        case invalidIVLength
        case invalidInput
        case operationFailed
        case unsupportedDigest
    }

    // MARK: - Signed byte bridge (Java byte[] is -128...127 in scripts)

    static func toSigned(_ data: Data) -> [Int] {
        return data.map { Int(Int8(bitPattern: $0)) }
    }

    static func fromSigned(_ values: [Int]) throws -> Data {
        var out = Data()
        out.reserveCapacity(values.count)
        for v in values {
            // Accept -128...255: scripts sometimes build unsigned values by hand.
            guard v >= -128 && v <= 255 else { throw CryptoError.invalidInput }
            out.append(UInt8(truncatingIfNeeded: v))
        }
        return out
    }

    // MARK: - Hex / Base64

    static func hexEncode(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Hutool HexUtil.decodeHex: odd length and non-hex characters are errors.
    static func hexDecode(_ text: String) throws -> Data {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { throw CryptoError.invalidInput }
        var out = Data()
        out.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else {
                throw CryptoError.invalidInput
            }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func isHex(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.utf8.count % 2 == 0 && (try? hexDecode(t)) != nil
    }

    /// Tolerant base64: whitespace, URL-safe alphabet and missing padding.
    static func base64Decode(_ text: String) -> Data? {
        var t = text.filter { !$0.isWhitespace }
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: - Digests

    private static func digestAlgorithm(_ name: String) throws -> (Int, Int) {
        switch name.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5": return (0, Int(CC_MD5_DIGEST_LENGTH))
        case "SHA1": return (1, Int(CC_SHA1_DIGEST_LENGTH))
        case "SHA256": return (2, Int(CC_SHA256_DIGEST_LENGTH))
        case "SHA384": return (3, Int(CC_SHA384_DIGEST_LENGTH))
        case "SHA512": return (4, Int(CC_SHA512_DIGEST_LENGTH))
        default: throw CryptoError.unsupportedDigest
        }
    }

    static func digest(_ data: Data, algorithm: String) throws -> Data {
        let (kind, length) = try digestAlgorithm(algorithm)
        var out = [UInt8](repeating: 0, count: length)
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress
            let n = CC_LONG(data.count)
            switch kind {
            case 0: _ = CC_MD5(p, n, &out)
            case 1: _ = CC_SHA1(p, n, &out)
            case 2: _ = CC_SHA256(p, n, &out)
            case 3: _ = CC_SHA384(p, n, &out)
            default: _ = CC_SHA512(p, n, &out)
            }
        }
        return Data(out)
    }

    static func hmac(_ data: Data, algorithm: String, key: Data) throws -> Data {
        let (kind, length) = try digestAlgorithm(algorithm)
        let alg: CCHmacAlgorithm
        switch kind {
        case 0: alg = CCHmacAlgorithm(kCCHmacAlgMD5)
        case 1: alg = CCHmacAlgorithm(kCCHmacAlgSHA1)
        case 2: alg = CCHmacAlgorithm(kCCHmacAlgSHA256)
        case 3: alg = CCHmacAlgorithm(kCCHmacAlgSHA384)
        default: alg = CCHmacAlgorithm(kCCHmacAlgSHA512)
        }
        var out = [UInt8](repeating: 0, count: length)
        key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                CCHmac(alg, k.baseAddress, key.count, d.baseAddress, data.count, &out)
            }
        }
        return Data(out)
    }

    static func digestHex(_ text: String, algorithm: String) throws -> String {
        return hexEncode(try digest(Data(text.utf8), algorithm: algorithm))
    }

    static func digestBase64(_ text: String, algorithm: String) throws -> String {
        return try digest(Data(text.utf8), algorithm: algorithm).base64EncodedString()
    }

    static func hmacHex(_ text: String, algorithm: String, key: String) throws -> String {
        return hexEncode(try hmac(Data(text.utf8), algorithm: algorithm, key: Data(key.utf8)))
    }

    static func hmacBase64(_ text: String, algorithm: String, key: String) throws -> String {
        return try hmac(Data(text.utf8), algorithm: algorithm, key: Data(key.utf8)).base64EncodedString()
    }

    // MARK: - Symmetric cipher

    final class Cipher {
        private let algorithm: CCAlgorithm
        private let blockSize: Int
        private let cbc: Bool
        private let padded: Bool
        private let key: Data
        private let iv: Data?

        /// `transformation` examples: "AES", "AES/CBC/PKCS5Padding", "DES/CBC/PKCS7Padding".
        /// A bare algorithm name means ECB with PKCS5 padding, as in Hutool.
        init(transformation: String, key: Data, iv: Data?) throws {
            let parts = transformation.split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard parts.count == 1 || parts.count == 3, !parts[0].isEmpty else {
                throw CryptoError.unsupportedTransformation
            }
            switch parts[0] {
            case "AES":
                algorithm = CCAlgorithm(kCCAlgorithmAES)
                blockSize = kCCBlockSizeAES128
                guard [16, 24, 32].contains(key.count) else { throw CryptoError.invalidKeyLength }
            case "DES":
                algorithm = CCAlgorithm(kCCAlgorithmDES)
                blockSize = kCCBlockSizeDES
                guard key.count == 8 else { throw CryptoError.invalidKeyLength }
            default:
                throw CryptoError.unsupportedTransformation
            }
            let mode = parts.count == 3 ? parts[1] : "ECB"
            let padding = parts.count == 3 ? parts[2] : "PKCS5PADDING"
            switch mode {
            case "ECB": cbc = false
            case "CBC": cbc = true
            default: throw CryptoError.unsupportedTransformation
            }
            switch padding {
            case "PKCS5PADDING", "PKCS7PADDING": padded = true
            case "NOPADDING": padded = false
            default: throw CryptoError.unsupportedTransformation
            }
            if cbc {
                // Hutool defaults to an all-zero IV only when none is given for CBC.
                let given = iv ?? Data()
                if given.isEmpty {
                    self.iv = Data(repeating: 0, count: blockSize)
                } else {
                    guard given.count == blockSize else { throw CryptoError.invalidIVLength }
                    self.iv = given
                }
            } else {
                self.iv = nil
            }
            self.key = key
        }

        private func run(_ data: Data, encrypt: Bool) throws -> Data {
            if !padded && !encrypt && data.count % blockSize != 0 { throw CryptoError.invalidInput }
            if !padded && encrypt && data.count % blockSize != 0 { throw CryptoError.invalidInput }
            var options: CCOptions = padded ? CCOptions(kCCOptionPKCS7Padding) : 0
            if !cbc { options |= CCOptions(kCCOptionECBMode) }
            var out = Data(count: data.count + blockSize)
            var moved = 0
            let outCapacity = out.count
            let status: CCCryptorStatus = out.withUnsafeMutableBytes { outRaw in
                data.withUnsafeBytes { inRaw in
                    key.withUnsafeBytes { keyRaw in
                        let op = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
                        if let iv = iv {
                            return iv.withUnsafeBytes { ivRaw in
                                CCCrypt(op, algorithm, options, keyRaw.baseAddress, key.count,
                                        ivRaw.baseAddress, inRaw.baseAddress, data.count,
                                        outRaw.baseAddress, outCapacity, &moved)
                            }
                        }
                        return CCCrypt(op, algorithm, options, keyRaw.baseAddress, key.count,
                                       nil, inRaw.baseAddress, data.count,
                                       outRaw.baseAddress, outCapacity, &moved)
                    }
                }
            }
            guard status == CCCryptorStatus(kCCSuccess) else { throw CryptoError.operationFailed }
            out.removeSubrange(moved..<out.count)
            return out
        }

        func encrypt(_ data: Data) throws -> Data { return try run(data, encrypt: true) }
        func decrypt(_ data: Data) throws -> Data { return try run(data, encrypt: false) }

        /// Hutool/SymmetricCryptoAndroid: hex if the whole string is hex, else base64.
        func decryptInput(_ text: String) throws -> Data {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes: Data
            if SourceCrypto.isHex(trimmed) {
                bytes = try SourceCrypto.hexDecode(trimmed)
            } else if let b = SourceCrypto.base64Decode(trimmed) {
                bytes = b
            } else {
                throw CryptoError.invalidInput
            }
            return try decrypt(bytes)
        }

        func decryptStr(_ text: String) throws -> String {
            let plain = try decryptInput(text)
            guard let s = String(data: plain, encoding: .utf8) else { throw CryptoError.invalidInput }
            return s
        }

        func encryptBase64(_ text: String) throws -> String {
            return try encrypt(Data(text.utf8)).base64EncodedString()
        }

        func encryptHex(_ text: String) throws -> String {
            return SourceCrypto.hexEncode(try encrypt(Data(text.utf8)))
        }
    }
}
