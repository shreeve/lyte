// SniffFormat: the header dissector behind `lyte-host sniff` (HS-5).
// One received datagram → one text line of decoded envelope + fec fields.
// The envelope rides as cleartext AAD by design (overview §2), so this
// formatter stays honest when Noise lands at HS-7 — only the payload
// bytes go dark, and payload decryption behind a key flag is explicitly
// a later slice (master plan's deferred list). Pure formatting, no IO:
// the Linux-only socket loop lives in lyte-host; this part runs (and is
// tested) on the Mac.

import LyteWire

public enum SniffFormat {
    /// Formats one datagram's decoded headers, e.g.
    ///
    ///   chan=2(video-active) seq=00042 frame=7 ts=1234567us
    ///   fec=rs idx=5/20 k=17 m=3 group=18400B payload=1112B total=1136B
    ///
    /// (one line; wrapped here for the comment). Malformed datagrams
    /// format as an error line rather than throwing — a sniffer must
    /// survive whatever the wire carries.
    public static func line(datagram: ArraySlice<UInt8>) -> String {
        let envelope: Envelope
        let payload: ArraySlice<UInt8>
        do {
            (envelope, payload) = try Envelope.decode(datagram)
        } catch {
            return "malformed len=\(datagram.count)B error=\(error)"
        }
        return line(
            envelope: envelope,
            payloadByteCount: payload.count,
            datagramByteCount: datagram.count
        )
    }

    public static func line(datagram: [UInt8]) -> String {
        line(datagram: datagram[...])
    }

    public static func line(
        envelope: Envelope, payloadByteCount: Int, datagramByteCount: Int
    ) -> String {
        var fields = [
            "chan=\(envelope.channel.rawValue)(\(channelName(envelope.channel)))",
            "seq=\(zeroPadded(envelope.seq.rawValue, width: 5))",
            "frame=\(envelope.frame.rawValue)",
            "ts=\(envelope.timestamp)us",
            fecDescription(envelope.fec),
        ]
        if !envelope.extensions.isEmpty {
            let types = envelope.extensions
                .map { "0x" + hexByte($0.type) }
                .joined(separator: ",")
            fields.append("tlv=[\(types)]")
        }
        fields.append("payload=\(payloadByteCount)B")
        fields.append("total=\(datagramByteCount)B")
        return fields.joined(separator: " ")
    }

    // MARK: - Interior

    static func channelName(_ channel: ChannelId) -> String {
        switch channel {
        case .ctrl: return "ctrl"
        case .audio: return "audio"
        case .videoActive: return "video-active"
        case .feedback: return "feedback"
        case .videoIdle: return "video-idle"
        default:
            if channel.isReserved { return "reserved" }
            if channel.isFeature { return "feature" }
            return "unknown"
        }
    }

    static func fecDescription(_ raw: UInt64) -> String {
        let field: FecField
        do {
            field = try FecField.decode(raw)
        } catch {
            return "fec=malformed(0x\(String(raw, radix: 16)))"
        }
        switch field {
        case .none:
            return "fec=none"
        case .reedSolomon(let shardIndex, let geometry):
            return "fec=rs idx=\(shardIndex)/\(geometry.totalShards) "
                + "k=\(geometry.dataShards) m=\(geometry.parityShards) "
                + "group=\(geometry.groupByteCount)B"
        }
    }

    static func zeroPadded(_ value: UInt16, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count))
            + digits
    }

    static func hexByte(_ value: UInt8) -> String {
        let digits = String(value, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }
}
