// Authors Vectors/audio-stream-off-v1.json: the key-14 (audioStreamOff)
// capability spine declared, absent, and composed with key 9, whose
// routing messages carry the streamOff mode. Anchored by
// AudioStreamOffVectorFileTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeAudioStreamOffVectorFile() throws -> AudioStreamOffVectorFile {
    AudioStreamOffVectorFile(vectors: try [
        ("capability-key14-declared",
         "wireDefault's frozen encoding plus exactly the appended `0E F5` "
            + "entry (map head 0xA8 → 0xA9): audioStreamOff reads true and "
            + "the set re-encodes byte-exactly.",
         Capabilities.wireDefault.declaringAudioStreamOff()),
        ("capability-key14-absent",
         "wireDefault's frozen encoding unchanged: audioStreamOff reads "
            + "false — \"not supported\", never an error.",
         Capabilities.wireDefault),
        ("capability-key9-and-key14",
         "Routing and stream-off together: map head 0xAA with `09 F5 0E F5` "
            + "trailing in canonical order — streamOff rides the key-9 "
            + "routing messages, so the two keys travel together.",
         Capabilities.wireDefault.declaringHostAudioRouting()
            .declaringAudioStreamOff()),
    ].map { name, description, set in
        CapabilitySpineVector(
            name: name, description: description,
            messageHex: Hex.string(try set.encodeCbor()),
            flags: [
                "audioStreamOff": set.audioStreamOff,
                "hostAudioRouting": set.hostAudioRouting,
            ]
        )
    })
}
