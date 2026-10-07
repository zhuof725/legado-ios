import Foundation

/// Known-answer tests, not round trips. Vector sources:
///  - AES-128/192/256 ECB and AES-128 CBC: NIST SP 800-38A F.1 / F.2 first block.
///  - DES ECB: classic 0x133457799BBCDFF1 key, 0x0123456789ABCDEF plaintext.
///  - Digests: FIPS 180 / RFC 1321 "abc" and empty-string vectors.
///  - HMAC-SHA256 / SHA512: RFC 4231 test case 2.
///  - PKCS-padded vectors were generated with pycryptodome and cross-checked
///    with Node's crypto module (AES), using synthetic data only.
enum SourceCryptoRegression {
    static func run(_ check: (Bool, String) -> Void) {
        func hex(_ s: String) -> Data { return try! SourceCrypto.hexDecode(s) }
        func enc(_ t: String, _ key: Data, _ iv: Data? = nil, _ pt: Data) -> String? {
            guard let c = try? SourceCrypto.Cipher(transformation: t, key: key, iv: iv),
                  let out = try? c.encrypt(pt) else { return nil }
            return SourceCrypto.hexEncode(out)
        }

        // NIST first-block vectors (NoPadding so the answer is the raw block).
        let pt = hex("6bc1bee22e409f96e93d7e117393172a")
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        check(enc("AES/ECB/NoPadding", hex("2b7e151628aed2a6abf7158809cf4f3c"), nil, pt) == "3ad77bb40d7a3660a89ecaf32466ef97", "AES-128 ECB NIST vector")
        check(enc("AES/CBC/NoPadding", hex("2b7e151628aed2a6abf7158809cf4f3c"), iv, pt) == "7649abac8119b246cee98e9b12e9197d", "AES-128 CBC NIST vector")
        check(enc("AES/ECB/NoPadding", hex("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b"), nil, pt) == "bd334f1d6e45f25ff712a214571fa5cc", "AES-192 ECB NIST vector")
        check(enc("AES/ECB/NoPadding", hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"), nil, pt) == "f3eed1bdb5d2a03c064b5a7e3db181f8", "AES-256 ECB NIST vector")
        check(enc("DES/ECB/NoPadding", hex("133457799bbcdff1"), nil, hex("0123456789abcdef")) == "85e813540f0ab405", "DES ECB classic vector")

        // Padded vectors as used by real sources.
        let key = Data("0123456789abcdef".utf8)
        let plain = Data("hello world".utf8)
        check(enc("AES", key, nil, plain) == "8169bed4ef49a8874559c5b200daade7", "bare AES means ECB with PKCS5")
        check(enc("AES/ECB/PKCS5Padding", key, nil, plain) == "8169bed4ef49a8874559c5b200daade7", "AES ECB PKCS5 vector")
        check(enc("aes/ecb/pkcs7padding", key, nil, plain) == "8169bed4ef49a8874559c5b200daade7", "transformation is case-insensitive and PKCS7 equals PKCS5")
        check(enc("AES/CBC/PKCS5Padding", key, Data("fedcba9876543210".utf8), plain) == "1230aa04e547a446d75c38ce7b6d10d6", "AES CBC PKCS5 vector")
        check(enc("AES/CBC/PKCS7Padding", key, nil, plain) == "8169bed4ef49a8874559c5b200daade7", "CBC without IV uses an all-zero IV")
        check(enc("DES/CBC/PKCS5Padding", Data("KW8Dvm2N".utf8), Data("1ae2c94b".utf8), Data("hello".utf8)) == "d90ea623277fbe3f", "DES CBC PKCS5 vector")

        // Decrypt input: hex when all hex, otherwise base64; both reach the same plaintext.
        if let c = try? SourceCrypto.Cipher(transformation: "AES/CBC/PKCS5Padding", key: key, iv: Data("fedcba9876543210".utf8)) {
            check((try? c.decryptStr("1230aa04e547a446d75c38ce7b6d10d6")) == "hello world", "decryptStr accepts hex")
            check((try? c.decryptStr("EjCqBOVHpEbXXDjOe20Q1g==")) == "hello world", "decryptStr accepts base64")
            check((try? c.decryptStr(" 1230AA04E547A446D75C38CE7B6D10D6\n")) == "hello world", "decryptStr tolerates whitespace and upper-case hex")
            check((try? c.encryptBase64("hello world")) == "EjCqBOVHpEbXXDjOe20Q1g==", "encryptBase64 has no line breaks")
            check((try? c.encryptHex("hello world")) == "1230aa04e547a446d75c38ce7b6d10d6", "encryptHex is lower-case")
            check((try? c.decryptStr("0000")) == nil, "wrong-length ciphertext throws instead of returning data")
            // With this key pycryptodome reports "Padding is incorrect" for the same bytes.
            if let wrong = try? SourceCrypto.Cipher(transformation: "AES/CBC/PKCS5Padding", key: Data("ffffffffffffffff".utf8), iv: Data("fedcba9876543210".utf8)) {
                check((try? wrong.decrypt(hex("1230aa04e547a446d75c38ce7b6d10d6"))) == nil, "wrong key reports a padding failure instead of data")
            } else {
                check(false, "cipher construction for wrong-key vector")
            }
        } else {
            check(false, "cipher construction for decrypt vectors")
        }

        // Padding is validated by this code, not trusted to CommonCrypto.
        // 16 bytes ending in 0x01 is valid padding; 0x00 and 0x11 are not (pycryptodome agrees).
        if let np = try? SourceCrypto.Cipher(transformation: "AES/ECB/PKCS5Padding", key: key, iv: nil),
           let raw = try? SourceCrypto.Cipher(transformation: "AES/ECB/NoPadding", key: key, iv: nil) {
            func tail(_ last: UInt8) -> Data {
                var block = Data(repeating: 0x41, count: 15); block.append(last)
                return (try? raw.encrypt(block)) ?? Data()
            }
            check((try? np.decrypt(tail(0x01))) == Data(repeating: 0x41, count: 15), "padding byte 0x01 is stripped")
            check((try? np.decrypt(tail(0x00))) == nil, "padding byte 0x00 is rejected")
            check((try? np.decrypt(tail(0x11))) == nil, "padding byte larger than the block is rejected")
            var inconsistent = Data(repeating: 0x41, count: 14); inconsistent.append(contentsOf: [0x07, 0x02])
            check((try? np.decrypt((try? raw.encrypt(inconsistent)) ?? Data())) == nil, "padding bytes that disagree are rejected")
            check((try? np.decrypt(Data())) == nil, "empty ciphertext is rejected")
            var full = Data(repeating: 0x10, count: 16)
            check((try? np.decrypt((try? raw.encrypt(full)) ?? Data())) == Data(), "a full padding block yields empty plaintext")
            full.removeAll()
        } else {
            check(false, "cipher construction for padding checks")
        }

        // Rejections are explicit.
        func rejects(_ t: String, _ k: Int, _ i: Int?, _ expected: SourceCrypto.CryptoError, _ label: String) {
            do {
                _ = try SourceCrypto.Cipher(transformation: t, key: Data(repeating: 1, count: k), iv: i.map { Data(repeating: 2, count: $0) })
                check(false, label)
            } catch let e as SourceCrypto.CryptoError { check(e == expected, label) }
            catch { check(false, label) }
        }
        rejects("AES", 15, nil, .invalidKeyLength, "AES rejects 15-byte key")
        rejects("DES", 16, nil, .invalidKeyLength, "DES rejects 16-byte key")
        rejects("AES/CBC/PKCS5Padding", 16, 8, .invalidIVLength, "CBC rejects short IV")
        rejects("RC4", 16, nil, .unsupportedTransformation, "unsupported algorithm is rejected")
        rejects("AES/CTR/NoPadding", 16, nil, .unsupportedTransformation, "unsupported mode is rejected")
        rejects("AES/CBC/ISO10126Padding", 16, nil, .unsupportedTransformation, "unsupported padding is rejected")
        rejects("AES/CBC", 16, nil, .unsupportedTransformation, "two-part transformation is rejected")
        rejects("", 16, nil, .unsupportedTransformation, "empty transformation is rejected")
        if let np = try? SourceCrypto.Cipher(transformation: "AES/ECB/NoPadding", key: key, iv: nil) {
            check((try? np.encrypt(Data("short".utf8))) == nil, "NoPadding rejects non-block-sized input")
        }

        // Digests and HMAC.
        func d(_ s: String, _ a: String) -> String? { return try? SourceCrypto.digestHex(s, algorithm: a) }
        check(d("abc", "MD5") == "900150983cd24fb0d6963f7d28e17f72", "MD5 abc")
        check(d("", "md5") == "d41d8cd98f00b204e9800998ecf8427e", "MD5 empty, name is case-insensitive")
        check(d("abc", "SHA-1") == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 abc, hyphenated name")
        check(d("abc", "SHA-256") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 abc")
        check(d("", "SHA256") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 empty")
        check(d("abc", "SHA-384") == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "SHA-384 abc")
        check(d("abc", "SHA-512") == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512 abc")
        check(d("", "SHA-512") == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e", "SHA-512 empty")
        check(d("abc", "CRC32") == nil, "unsupported digest throws")
        check((try? SourceCrypto.digestBase64("abc", algorithm: "MD5")) == "kAFQmDzST7DWlj99KOF/cg==", "digestBase64 MD5 abc")
        check((try? SourceCrypto.hmacHex("what do ya want for nothing?", algorithm: "SHA-256", key: "Jefe")) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA256 RFC 4231 case 2")
        check((try? SourceCrypto.hmacHex("what do ya want for nothing?", algorithm: "SHA-512", key: "Jefe")) == "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737", "HMAC-SHA512 RFC 4231 case 2")
        check((try? SourceCrypto.hmacHex("abc", algorithm: "MD5", key: "k")) == "75972c9c6569f2f407752ddb02ac79de", "HMAC-MD5 vector")
        check((try? SourceCrypto.hmacBase64("abc", algorithm: "MD5", key: "k")) == Data(hex("75972c9c6569f2f407752ddb02ac79de")).base64EncodedString(), "HMAC base64 matches hex form")

        // Byte helpers.
        check(SourceCrypto.toSigned(Data([0x00, 0x7f, 0x80, 0xff])) == [0, 127, -128, -1], "unsigned to Java signed bytes")
        check((try? SourceCrypto.fromSigned([0, 127, -128, -1])) == Data([0x00, 0x7f, 0x80, 0xff]), "Java signed bytes to data")
        check((try? SourceCrypto.fromSigned([200])) == Data([200]), "hand-built unsigned byte value is accepted")
        check((try? SourceCrypto.fromSigned([256])) == nil && (try? SourceCrypto.fromSigned([-129])) == nil, "out-of-range byte values are rejected")
        check((try? SourceCrypto.hexDecode("00ff10")) == Data([0x00, 0xff, 0x10]), "hex decode")
        check((try? SourceCrypto.hexDecode("abc")) == nil, "odd-length hex is rejected")
        check((try? SourceCrypto.hexDecode("zz")) == nil, "non-hex characters are rejected")
        check(SourceCrypto.isHex("00ff") && !SourceCrypto.isHex("abc") && !SourceCrypto.isHex("") && !SourceCrypto.isHex("EjCq"), "hex detection boundaries")
        check(SourceCrypto.hexEncode(Data([0x00, 0xff, 0x10])) == "00ff10", "hex encode is lower-case")
        check(SourceCrypto.base64Decode("AP8Q") == Data([0x00, 0xff, 0x10]), "base64 decode")
        check(SourceCrypto.base64Decode("AP8") == Data([0x00, 0xff]), "base64 decode tolerates missing padding")
        check(SourceCrypto.base64Decode("A P\n8Q") == Data([0x00, 0xff, 0x10]), "base64 decode ignores whitespace")
        check(SourceCrypto.base64Decode("-_-_") == SourceCrypto.base64Decode("+/+/"), "base64 decode accepts the URL-safe alphabet")
    }
}
