// The one registry of vector-file builders. The authoring tool and the
// regeneration test both read it, and the test requires it to name every
// committed `Vectors/*.json` file exactly once, so a file without a
// builder (or a builder without a file) fails the suite.

import LyteWireTestKit

/// One committed vector file and the builder that authors it.
public struct VectorFileBuilder: Sendable {
    /// The authoring tool's name for the file.
    public let kind: String
    /// The file's name under `Wire/Vectors/`.
    public let fileName: String
    /// Builds the file from the codecs.
    public let build: @Sendable () throws -> any FrozenVectorFile
    /// Decodes the committed file as the builder's type.
    public let loadCommitted: @Sendable () throws -> any FrozenVectorFile

    init<File: FrozenVectorFile>(
        _ kind: String, _ build: @escaping @Sendable () throws -> File
    ) {
        self.kind = kind
        self.fileName = File.fileName
        self.build = build
        self.loadCommitted = { try File.loadCommitted() }
    }
}

/// Every vector file's builder, in authoring order.
public let vectorFileBuilders: [VectorFileBuilder] = [
    VectorFileBuilder("envelope", makeEnvelopeVectorFile),
    VectorFileBuilder("fec", makeFecVectorFile),
    VectorFileBuilder("video") {
        try makeVideoVectorFile(
            corpusDirectory: WireVectors.path("video-corpus-v1")
        )
    },
    VectorFileBuilder("beacon", makeBeaconVectorFile),
    VectorFileBuilder("noise", makeNoiseVectorFile),
    VectorFileBuilder("session", makeSessionVectorFile),
    VectorFileBuilder("arq", makeArqVectorFile),
    VectorFileBuilder("lifecycle", makeLifecycleVectorFile),
    VectorFileBuilder("pairing", makePairingVectorFile),
    VectorFileBuilder("capabilities", makeCapabilityVectorFile),
    VectorFileBuilder("retry", makeRetryVectorFile),
    VectorFileBuilder("control", makeControlVectorFile),
    VectorFileBuilder("clipboard", makeClipboardVectorFile),
    VectorFileBuilder("bulk", makeBulkVectorFile),
    VectorFileBuilder("clipboard-images", makeClipboardImageVectorFile),
    VectorFileBuilder("cursor", makeCursorVectorFile),
    VectorFileBuilder("repair-refusal", makeRepairRefusalVectorFile),
    VectorFileBuilder("postures", makePostureVectorFile),
    VectorFileBuilder("input-coordinates", makeInputCoordinateVectorFile),
]
