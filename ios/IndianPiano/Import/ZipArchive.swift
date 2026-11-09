import Compression
import Foundation

/// Minimal read-only ZIP reader (stored and deflate entries, no ZIP64), enough for `.mxl`.
struct ZipArchive {
    struct Entry: Equatable {
        var path: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    let entries: [Entry]
    private let bytes: [UInt8]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ScoreImportError.invalidFormat("archive is too small") }

        var endRecord: Int?
        var offset = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while offset >= lowest {
            if Self.u32(bytes, offset) == 0x0605_4B50 { endRecord = offset; break }
            offset -= 1
        }
        guard let endRecord else { throw ScoreImportError.invalidFormat("missing ZIP directory") }

        let count = Int(Self.u16(bytes, endRecord + 10))
        var cursor = Int(Self.u32(bytes, endRecord + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, Self.u32(bytes, cursor) == 0x0201_4B50 else {
                throw ScoreImportError.invalidFormat("corrupt ZIP directory")
            }
            let nameLength = Int(Self.u16(bytes, cursor + 28))
            let extraLength = Int(Self.u16(bytes, cursor + 30))
            let commentLength = Int(Self.u16(bytes, cursor + 32))
            guard cursor + 46 + nameLength <= bytes.count else { throw ScoreImportError.invalidFormat("corrupt ZIP entry name") }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                path: name,
                method: Self.u16(bytes, cursor + 10),
                compressedSize: Int(Self.u32(bytes, cursor + 20)),
                uncompressedSize: Int(Self.u32(bytes, cursor + 24)),
                localHeaderOffset: Int(Self.u32(bytes, cursor + 42))
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func entry(named path: String) -> Entry? {
        entries.first { $0.path == path } ?? entries.first { $0.path.lowercased() == path.lowercased() }
    }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4B50 else {
            throw ScoreImportError.invalidFormat("corrupt ZIP entry \(entry.path)")
        }
        let start = header + 30 + Int(Self.u16(bytes, header + 26)) + Int(Self.u16(bytes, header + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ScoreImportError.invalidFormat("truncated ZIP entry \(entry.path)") }
        let payload = Array(bytes[start..<end])

        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return try Self.inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ScoreImportError.invalidFormat("unsupported ZIP compression method \(entry.method)")
        }
    }

    /// Raw DEFLATE (RFC 1951) decode; Apple's `COMPRESSION_ZLIB` is headerless deflate.
    static func inflate(_ input: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, expectedSize, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ScoreImportError.invalidFormat("couldn't decompress archive entry") }
        return Data(output)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
