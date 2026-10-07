import Foundation
import Compression

/// 最小 ZIP 读取器（够读 EPUB）：解析中央目录，支持 Stored(0) 与 Deflate(8)，不支持加密与 ZIP64。
/// 不加外部依赖。解压大小有上限，防止恶意压缩包撑爆内存。
struct ZipReader {
    struct Entry { let name: String; let method: Int; let compressedSize: Int; let size: Int; let localOffset: Int }
    enum ZipError: Error { case notZip, unsupported, corrupt, tooLarge }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    static let maxEntryBytes = 64 * 1024 * 1024

    init(data: Data) throws {
        self.data = data
        guard data.count > 22 else { throw ZipError.notZip }
        // 从尾部找 End Of Central Directory（0x06054b50）。
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocd = -1
        let lower = max(0, data.count - 22 - 65535)
        var i = data.count - 22
        while i >= lower {
            if data[i] == sig[0], data[i + 1] == sig[1], data[i + 2] == sig[2], data[i + 3] == sig[3] { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let total = Int(ZipReader.u16(data, eocd + 10))
        var p = Int(ZipReader.u32(data, eocd + 16))
        guard p < data.count else { throw ZipError.corrupt }
        for _ in 0..<total {
            guard p + 46 <= data.count, ZipReader.u32(data, p) == 0x02014b50 else { throw ZipError.corrupt }
            let flags = Int(ZipReader.u16(data, p + 8))
            let method = Int(ZipReader.u16(data, p + 10))
            let csize = Int(ZipReader.u32(data, p + 20))
            let usize = Int(ZipReader.u32(data, p + 24))
            let nlen = Int(ZipReader.u16(data, p + 28))
            let elen = Int(ZipReader.u16(data, p + 30))
            let clen = Int(ZipReader.u16(data, p + 32))
            let off = Int(ZipReader.u32(data, p + 42))
            guard p + 46 + nlen <= data.count else { throw ZipError.corrupt }
            if flags & 1 != 0 { throw ZipError.unsupported }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nlen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, size: usize, localOffset: off)
            p += 46 + nlen + elen + clen
        }
    }

    func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw ZipError.corrupt }
        guard e.size <= ZipReader.maxEntryBytes else { throw ZipError.tooLarge }
        let lh = e.localOffset
        guard lh + 30 <= data.count, ZipReader.u32(data, lh) == 0x04034b50 else { throw ZipError.corrupt }
        let nlen = Int(ZipReader.u16(data, lh + 26))
        let elen = Int(ZipReader.u16(data, lh + 28))
        let start = lh + 30 + nlen + elen
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt }
        let raw = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8: return try ZipReader.inflate(raw, expected: e.size)
        default: throw ZipError.unsupported
        }
    }

    private static func inflate(_ raw: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        var out = Data(count: expected)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            raw.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // Compression 的 COMPRESSION_ZLIB 是裸 deflate（无 zlib 头），正好对应 ZIP 的 Deflate。
                return compression_decode_buffer(d, expected, s, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expected else { throw ZipError.corrupt }
        return out
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
}
