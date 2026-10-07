import Foundation

/// Production JS -> native bridge for crypto and codecs. Synthetic values only.
/// Expected values are the same known-answer vectors as SourceCryptoRegression
/// (pycryptodome, cross-checked with Node crypto).
enum CryptoBridgeRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let engine = JSEngine.shared
        func js(_ script: String) -> String { return engine.evalString(script) ?? "<nil>" }

        check(js("""
            var c=java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','fedcba9876543210');
            c.encryptHex('hello world');
            """) == "1230aa04e547a446d75c38ce7b6d10d6", "script AES CBC encryptHex matches the known vector")
        check(js("""
            var c=java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','fedcba9876543210');
            [c.encryptBase64('hello world'), c.decryptStr('EjCqBOVHpEbXXDjOe20Q1g=='),
             c.decryptStr('1230aa04e547a446d75c38ce7b6d10d6')].join('|');
            """) == "EjCqBOVHpEbXXDjOe20Q1g==|hello world|hello world", "script encryptBase64 and decryptStr accept hex and base64")
        check(js("""
            var key=java.strToBytes('0123456789abcdef');
            var c=java.createSymmetricCrypto('AES',key);
            [c.decryptStr(c.encrypt('hello world')), java.bytesToStr(c.decrypt(c.encrypt(java.strToBytes('hi')))),
             Array.isArray(c.encrypt('x'))].join('|');
            """) == "hello world|hi|true", "byte-array arguments and results work through the bridge")
        check(js("""
            var c=java.createSymmetricCrypto('AES','0123456789abcdef');
            JSON.stringify(c.encrypt('hello world').slice(0,4));
            """) == "[-127,105,-66,-44]", "encrypt returns Java-style signed bytes (0x81,0x69,0xbe,0xd4)")
        check(js("""
            var c=java.createSymmetricCrypto('DES/CBC/PKCS5Padding','KW8Dvm2N','1ae2c94b');
            c.encryptHex('hello');
            """) == "d90ea623277fbe3f", "script DES CBC vector")
        // 3DES（DESede）已知答案向量，由 openssl des-ede3 生成。
        check(js("java.tripleDESEncodeBase64Str('hello world','{1dYgqE)h9,R)hKqEcv4]k[h','CBC','PKCS5Padding','01234567')")
              == "/iXAps4V2Ixuc5BZ1/gH3A==", "script 3DES CBC encryptBase64 matches openssl vector")
        check(js("java.tripleDESEncodeBase64Str('abc','0821CAAD409B84020821CAAD','CBC','PKCS5Padding',String.fromCharCode(0,0,0,0,0,0,0,0))")
              == "/gNfGJkAzrw=", "script 3DES CBC with all-zero IV string")
        check(js("java.tripleDESDecodeStr('/iXAps4V2Ixuc5BZ1/gH3A==','{1dYgqE)h9,R)hKqEcv4]k[h','CBC','PKCS5Padding','01234567')")
              == "hello world", "script 3DES decode round trip")
        check(js("var c=java.createSymmetricCrypto('DESede/ECB/PKCS5Padding','{1dYgqE)h9,R)hKqEcv4]k[h');c.encryptBase64('hello world')")
              == "/fFlPDrFqXAGaj2LRQTjGw==", "script 3DES ECB vector")
        check(js("(function(){try{java.tripleDESEncodeBase64Str('x','short','CBC','PKCS5Padding','01234567');return 'no';}catch(e){return 'throws';}})()")
              == "throws", "3DES rejects a key that is not 24 bytes")
        check(js("[java.getThemeMode(),typeof java.refreshContent,typeof java.refreshExplore].join('|')")
              == "6|function|function", "theme/refresh helpers exist")
        check(js("[java.digestHex('abc','SHA-256').slice(0,8), java.digestHex('abc','MD5'), java.digestBase64Str('abc','MD5')].join('|')")
              == "ba7816bf|900150983cd24fb0d6963f7d28e17f72|kAFQmDzST7DWlj99KOF/cg==", "script digests")
        check(js("java.HMacHex('what do ya want for nothing?','SHA-256','Jefe')")
              == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "script HMAC RFC 4231 vector")
        check(js("[JSON.stringify(java.hexDecodeToByteArray('00ff10')), JSON.stringify(java.base64DecodeToByteArray('AP8Q')), String(java.base64DecodeToByteArray('  '))].join('|')")
              == "[0,-1,16]|[0,-1,16]|null", "script hex/base64 byte decoding, blank base64 gives null like Kotlin")

        // Failures are catchable and never fake success.
        func errorName(_ body: String) -> String {
            return js("(function(){try{\(body);return 'no-error';}catch(e){return e.name+':'+e.message;}})();")
        }
        check(errorName("java.createSymmetricCrypto('AES','short')") == "CryptoError:Invalid key length", "bad key length is a catchable CryptoError")
        check(errorName("java.createSymmetricCrypto('RC4','0123456789abcdef')") == "CryptoError:Unsupported cipher transformation", "unsupported algorithm is a catchable CryptoError")
        check(errorName("java.digestHex('abc','CRC32')") == "CryptoError:Unsupported digest algorithm", "unsupported digest is a catchable CryptoError")
        check(errorName("java.hexDecodeToByteArray('abc')") == "CryptoError:Invalid crypto input", "odd-length hex is a catchable CryptoError")
        check(errorName("java.createSymmetricCrypto('AES','0123456789abcdef').decryptStr('0000')") == "CryptoError:Invalid crypto input"
              || errorName("java.createSymmetricCrypto('AES','0123456789abcdef').decryptStr('0000')").hasPrefix("CryptoError:"),
              "bad ciphertext is a catchable CryptoError")
        check(!errorName("java.createSymmetricCrypto('AES','short')").contains("short"), "error text does not echo key material")

        // Device identifier: stable within a process and shaped like ANDROID_ID.
        let a = js("java.androidId()"), b = js("java.deviceID()")
        check(a.count == 16 && a == b && a == JSEngine.installIdentifier, "androidId/deviceID are one stable 16-char identifier")
        check(a.allSatisfy { "0123456789abcdef".contains($0) }, "device identifier is lower-case hex")
    }
}
