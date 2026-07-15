import Foundation

/// Builders for Moonlight input events (Input.h wire structs, Sunshine Gen7+).
/// Each function returns the payload of an NVCTL input-data (0x0206) message,
/// which rides the encrypted control stream on a per-device ENet channel.
///
/// Wire layout: NV_INPUT_HEADER { size BE32 (excluding itself); magic LE32 }
/// followed by the event body. Coordinate and delta fields are big-endian;
/// keyCode is little-endian (matches InputStream.c exactly).
public enum InputPacket {
    public static let channelKeyboard: UInt8 = 0x02
    public static let channelMouse: UInt8 = 0x03
    public static let channelUTF8: UInt8 = 0x06

    public enum MouseButton: UInt8, Sendable {
        case left = 1, middle = 2, right = 3, x1 = 4, x2 = 5
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 0x01)
        public static let ctrl  = Modifiers(rawValue: 0x02)
        public static let alt   = Modifiers(rawValue: 0x04)
        public static let meta  = Modifiers(rawValue: 0x08)
    }

    /// One "click" of a traditional mouse wheel (Windows WHEEL_DELTA).
    public static let wheelDelta: Int = 120

    // MARK: - Keyboard

    public static func keyEvent(down: Bool, windowsVK: UInt16, modifiers: Modifiers) -> Data {
        var d = header(bodySize: 6, magic: down ? 0x0000_0003 : 0x0000_0004)
        d.append(0)                          // flags (Sunshine ext; 0 = normalized)
        d.append(le16(windowsVK))
        d.append(modifiers.rawValue)
        d.append(contentsOf: [0, 0])         // zero2
        return d
    }

    /// UTF-8 text injection (≤32 bytes per packet).
    public static func utf8Text(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 32 else { return nil }
        var d = header(bodySize: bytes.count, magic: 0x0000_0017)
        d.append(contentsOf: bytes)
        return d
    }

    // MARK: - Mouse

    public static func mouseMoveRelative(dx: Int16, dy: Int16) -> Data {
        var d = header(bodySize: 4, magic: 0x0000_0007)   // MOUSE_MOVE_REL_MAGIC_GEN5
        d.append(be16(UInt16(bitPattern: dx)))
        d.append(be16(UInt16(bitPattern: dy)))
        return d
    }

    /// Absolute position in an arbitrary reference space; the host scales
    /// x/y by (width, height). Reference dims get the GFE -1 rounding fix.
    public static func mouseMoveAbsolute(x: Int16, y: Int16, width: Int16, height: Int16) -> Data {
        var d = header(bodySize: 10, magic: 0x0000_0005)
        d.append(be16(UInt16(bitPattern: x)))
        d.append(be16(UInt16(bitPattern: y)))
        d.append(contentsOf: [0, 0])         // unused
        d.append(be16(UInt16(bitPattern: width - 1)))
        d.append(be16(UInt16(bitPattern: height - 1)))
        return d
    }

    public static func mouseButton(down: Bool, button: MouseButton) -> Data {
        var d = header(bodySize: 1, magic: down ? 0x0000_0008 : 0x0000_0009)  // GEN5 magics
        d.append(button.rawValue)
        return d
    }

    /// Vertical scroll; positive = away from user. High-resolution units
    /// (120 = one wheel click).
    public static func scroll(amount: Int16) -> Data {
        var d = header(bodySize: 6, magic: 0x0000_000A)   // SCROLL_MAGIC_GEN5
        let amt = be16(UInt16(bitPattern: amount))
        d.append(amt)
        d.append(amt)                        // scrollAmt2 mirrors scrollAmt1
        d.append(contentsOf: [0, 0])         // zero3
        return d
    }

    /// Horizontal scroll (Sunshine protocol extension); positive = right.
    public static func hscroll(amount: Int16) -> Data {
        var d = header(bodySize: 2, magic: 0x5500_0001)
        d.append(be16(UInt16(bitPattern: amount)))
        return d
    }

    // MARK: - Helpers

    private static func header(bodySize: Int, magic: UInt32) -> Data {
        var d = Data(capacity: 8 + bodySize)
        d.append(be32(UInt32(4 + bodySize)))   // size excludes the size field itself
        d.append(le32(magic))
        return d
    }

    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }
}
