import Foundation
import zlib

/// Minimal STORED-only ZIP writer. Used for synthetic test volumes and, if
/// the open question resolves that way, for writing ComicInfo.xml into
/// imported archives. Entry order is preserved exactly as given.
public enum ZipWriter {
    public struct Entry: Sendable { public let name: String; public let data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data } }

    public static func stored(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(.now)
        for e in entries {
            let name = Data(e.name.utf8)
            let crc = e.data.withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(e.data.count)) }
            let offset = UInt32(out.count)
            var lh = Data()
            lh.u32(0x0403_4b50); lh.u16(20); lh.u16(0x800); lh.u16(0); lh.u16(dosTime); lh.u16(dosDate)
            lh.u32(UInt32(crc)); lh.u32(UInt32(e.data.count)); lh.u32(UInt32(e.data.count))
            lh.u16(UInt16(name.count)); lh.u16(0)
            out.append(lh); out.append(name); out.append(e.data)
            var ch = Data()
            ch.u32(0x0201_4b50); ch.u16(0x031E); ch.u16(20); ch.u16(0x800); ch.u16(0); ch.u16(dosTime); ch.u16(dosDate)
            ch.u32(UInt32(crc)); ch.u32(UInt32(e.data.count)); ch.u32(UInt32(e.data.count))
            ch.u16(UInt16(name.count)); ch.u16(0); ch.u16(0); ch.u16(0); ch.u16(0); ch.u32(0o100644 << 16); ch.u32(offset)
            central.append(ch); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        var eocd = Data()
        eocd.u32(0x0605_4b50); eocd.u16(0); eocd.u16(0); eocd.u16(UInt16(entries.count)); eocd.u16(UInt16(entries.count))
        eocd.u32(UInt32(central.count)); eocd.u32(cdOffset); eocd.u16(0)
        out.append(eocd)
        return out
    }

    private static func dosDateTime(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let dt = UInt16(((c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (t, dt)
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
    mutating func u32(_ v: UInt32) { append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]) }
}
