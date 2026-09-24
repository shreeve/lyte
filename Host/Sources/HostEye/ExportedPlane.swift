// One exported plane of a VAAPI surface (a dmabuf fd plus its layout):
// the contract between the encoder's surface pool and the GL blit.

#if os(Linux)

public struct ExportedPlane {
    public var fourcc: UInt32
    public var modifier: UInt64
    public var fd: Int32
    public var offset: UInt32
    public var pitch: UInt32
}

#endif
