// ExportedPlane: one exported NV12 plane of a VAAPI surface — the
// contract between the encoder's surface pool and the GL blit's
// render targets (a dmabuf fd plus its layout). Born inside the
// libav EyeEncoder (E1), it outlived its parent when the eye's
// libavcodec seat was demolished after first-light: the native
// EyeVaapiEncoder's exportSurface speaks it now.

#if os(Linux)

public struct ExportedPlane {
    public var fourcc: UInt32
    public var modifier: UInt64
    public var fd: Int32
    public var offset: UInt32
    public var pitch: UInt32
}

#endif
