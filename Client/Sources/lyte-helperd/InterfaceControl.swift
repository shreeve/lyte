import Darwin
import Foundation

/// awdl0's up/down switch and the routing-socket reading that tells when
/// the system raised it again. Flag changes use the same
/// SIOCGIFFLAGS/SIOCSIFFLAGS pair ifconfig uses, in-process — no fork per
/// re-assertion.
enum InterfaceControl {
    static let awdl = "awdl0"

    // _IOWR('i', 17, struct ifreq) and _IOW('i', 16, struct ifreq):
    // function-like macros are not imported into Swift.
    private static let ifreqSize = UInt(MemoryLayout<ifreq>.size)
    static let getFlagsRequest: UInt = 0xC000_0000
        | ((ifreqSize & 0x1FFF) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 17
    static let setFlagsRequest: UInt = 0x8000_0000
        | ((ifreqSize & 0x1FFF) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 16

    static func index(of name: String) -> UInt16? {
        let index = if_nametoindex(name)
        return index == 0 ? nil : UInt16(truncatingIfNeeded: index)
    }

    /// The interface's flags (IFF_*), nil when it does not exist.
    static func flags(of name: String) -> Int32? {
        withControlSocket { fd in
            var request = makeRequest(name)
            guard ioctl(fd, getFlagsRequest, &request) == 0 else { return nil }
            return Int32(UInt16(bitPattern: request.ifr_ifru.ifru_flags))
        } ?? nil
    }

    /// Sets or clears IFF_UP; requires root. Returns false when the
    /// interface is missing or the kernel refused.
    @discardableResult
    static func setUp(_ name: String, up: Bool) -> Bool {
        withControlSocket { fd in
            var request = makeRequest(name)
            guard ioctl(fd, getFlagsRequest, &request) == 0 else { return false }
            var flags = UInt16(bitPattern: request.ifr_ifru.ifru_flags)
            let upFlag = UInt16(IFF_UP)
            let isUp = flags & upFlag != 0
            guard isUp != up else { return true }
            flags = up ? flags | upFlag : flags & ~upFlag
            request.ifr_ifru.ifru_flags = Int16(bitPattern: flags)
            return ioctl(fd, setFlagsRequest, &request) == 0
        } ?? false
    }

    /// True when one routing-socket message reports `interfaceIndex`
    /// with IFF_UP set (an RTM_IFINFO whose interface is up).
    static func isUpEdge(
        routingMessage message: ArraySlice<UInt8>, interfaceIndex: UInt16
    ) -> Bool {
        let typeOffset = MemoryLayout<if_msghdr>.offset(of: \.ifm_type)!
        let flagsOffset = MemoryLayout<if_msghdr>.offset(of: \.ifm_flags)!
        let indexOffset = MemoryLayout<if_msghdr>.offset(of: \.ifm_index)!
        guard message.count >= indexOffset + 2 else { return false }
        return message.withUnsafeBytes { raw -> Bool in
            guard raw[typeOffset] == UInt8(RTM_IFINFO) else { return false }
            let index = raw.loadUnaligned(fromByteOffset: indexOffset, as: UInt16.self)
            let flags = raw.loadUnaligned(fromByteOffset: flagsOffset, as: Int32.self)
            return index == interfaceIndex && flags & Int32(IFF_UP) != 0
        }
    }

    private static func makeRequest(_ name: String) -> ifreq {
        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { buffer in
            for (i, byte) in name.utf8.prefix(buffer.count - 1).enumerated() {
                buffer[i] = byte
            }
        }
        return request
    }

    private static func withControlSocket<T>(_ body: (Int32) -> T) -> T? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return body(fd)
    }
}
