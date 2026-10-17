import Foundation

/// CRC-16/XMODEM (poly 0x1021, init 0, no reflection) over `msgId + payload`.
public func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
    var crc: UInt16 = 0
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

/// One Samsung SPP frame: `FD [hdr lo][hdr hi] [msgId] payload… [crc lo][crc hi] DD`.
public struct Frame: Sendable, Equatable {
    public static let som: UInt8 = 0xFD
    public static let eom: UInt8 = 0xDD

    public var id: UInt8
    public var payload: [UInt8]
    /// Upper header bits (everything above the 10-bit size) as received. Requests send 0.
    public var flags: UInt16

    public init(_ id: UInt8, _ payload: [UInt8] = [], flags: UInt16 = 0) {
        self.id = id
        self.payload = payload
        self.flags = flags
    }

    public init(_ id: MsgID, _ payload: [UInt8] = []) {
        self.init(id.rawValue, payload)
    }

    public var msg: MsgID? { MsgID(rawValue: id) }

    /// Wire encoding. The type bit (0x1000) stays 0 for requests, which is what the buds accept.
    public func encoded() -> [UInt8] {
        let size = UInt16(1 + payload.count + 2)
        let header = (size & 0x03FF) | (flags & 0xFC00)
        let crc = crc16([id] + payload)
        return [Self.som, UInt8(header & 0xFF), UInt8(header >> 8), id]
            + payload
            + [UInt8(crc & 0xFF), UInt8(crc >> 8), Self.eom]
    }

    public var name: String { msg.map { "\($0)" } ?? String(format: "0x%02X", id) }
}

/// Incremental parser for the RFCOMM byte stream. Frames can be split across callbacks or glued
/// together, so bytes are buffered and complete frames are popped off the front.
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var droppedBytes = 0

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Frame] {
        buffer += bytes
        var frames: [Frame] = []
        while true {
            // Resync on the next start-of-message marker.
            guard let start = buffer.firstIndex(of: Frame.som) else {
                droppedBytes += buffer.count
                buffer.removeAll()
                break
            }
            if start > 0 {
                droppedBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 6 else { break }

            let header = UInt16(buffer[1]) | UInt16(buffer[2]) << 8
            let size = Int(header & 0x03FF)
            let total = size + 4
            guard size >= 3 else { dropOne(); continue }
            guard buffer.count >= total else { break }

            let id = buffer[3]
            let payload = Array(buffer[4..<(4 + size - 3)])
            let crcWire = UInt16(buffer[total - 3]) | UInt16(buffer[total - 2]) << 8
            guard buffer[total - 1] == Frame.eom, crc16([id] + payload) == crcWire else {
                dropOne()
                continue
            }
            frames.append(Frame(id, payload, flags: header & 0xFC00))
            buffer.removeFirst(total)
        }
        return frames
    }

    private mutating func dropOne() {
        droppedBytes += 1
        buffer.removeFirst()
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Parses "78 01", "7801" or "0x78,0x01".
    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
