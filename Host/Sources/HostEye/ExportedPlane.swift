// ExportedPlane: one exported NV12 plane of a VAAPI surface — the
// contract between the encoder's surface pool and the GL blit's
// render targets (a dmabuf fd plus its layout), produced by
// EyeVaapiEncoder.exportSurface.

#if os(Linux)

public struct ExportedPlane {
    public var fourcc: UInt32
    public var modifier: UInt64
    public var fd: Int32
    public var offset: UInt32
    public var pitch: UInt32
}

#endif
