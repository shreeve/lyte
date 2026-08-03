// EyeGL: the 3D-engine leg of the direct eye — headless EGL on the
// render node (GBM platform, surfaceless desktop-GL context), the
// modifier-aware dmabuf import the ccs-import-probe proved, and the
// RGB→NV12 blit (BT.709 limited range) into VAAPI-exported planes.
// All via module maps; the single extension-only entry point
// (glEGLImageTargetTexture2DOES) loads through eglGetProcAddress.

#if os(Linux)

import CEGL
import CGBM
import Foundation
import Glibc

private typealias ImageTargetTexture2D =
    @convention(c) (GLenum, UnsafeMutableRawPointer?) -> Void

// EGL_LINUX_DMA_BUF_EXT per-plane attribute names, indexable.
private let planeFdAttrs = [
    EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
    EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT,
]
private let planeOffsetAttrs = [
    EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
    EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT,
]
private let planePitchAttrs = [
    EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
    EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT,
]
private let planeModLoAttrs = [
    EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
    EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
]
private let planeModHiAttrs = [
    EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
    EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
]

public struct EyeGLError: Error, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}

/// One imported dmabuf as a bindable GL texture.
public struct ImportedTexture {
    public var image: EGLImage?
    public var texture: GLuint
}

/// One NV12 render target: the two planes as FBO-attached textures.
public struct NV12Target {
    public var y: ImportedTexture
    public var uv: ImportedTexture
    public var fboY: GLuint
    public var fboUV: GLuint
    public var width: Int32
    public var height: Int32
}

/// One packed-AYUV render target (the Rext 4:4:4 tier): a single
/// plane, imported as ARGB8888 so one shader pass writes all three
/// components at full resolution.
public struct AyuvTarget {
    public var plane: ImportedTexture
    public var fbo: GLuint
    public var width: Int32
    public var height: Int32
}

public final class EyeGL {
    private var nodeFd: Int32 = -1
    private var gbm: OpaquePointer?
    private var display: EGLDisplay?
    private var context: EGLContext?
    private var imageTarget: ImageTargetTexture2D!
    private var progY: GLuint = 0
    private var progUV: GLuint = 0
    private var prog444: GLuint = 0
    private var srcSizeLocY: GLint = -1
    private var srcSizeLocUV: GLint = -1
    private var srcSizeLoc444: GLint = -1

    public init(renderNode: String) throws {
        nodeFd = open(renderNode, O_RDWR)
        guard nodeFd >= 0 else {
            throw EyeGLError("open(\(renderNode)) failed: errno \(errno)")
        }
        gbm = gbm_create_device(nodeFd)
        guard let gbm else { throw EyeGLError("gbm_create_device failed") }
        display = eglGetPlatformDisplay(
            EGLenum(EGL_PLATFORM_GBM_KHR),
            UnsafeMutableRawPointer(gbm), nil)
        guard let display, eglInitialize(display, nil, nil) == EGL_TRUE else {
            throw EyeGLError("eglInitialize failed")
        }
        guard eglBindAPI(EGLenum(EGL_OPENGL_API)) == EGL_TRUE else {
            throw EyeGLError("eglBindAPI(OPENGL) failed")
        }
        // Surfaceless, configless context — the probe-proven recipe.
        let ctxAttribs: [EGLint] = [EGLint(EGL_NONE)]
        context = ctxAttribs.withUnsafeBufferPointer {
            eglCreateContext(display, nil, nil, $0.baseAddress)
        }
        guard let context,
              eglMakeCurrent(display, nil, nil, context) == EGL_TRUE else {
            throw EyeGLError(
                "EGL context failed: 0x\(String(eglGetError(), radix: 16))")
        }
        guard let proc = eglGetProcAddress("glEGLImageTargetTexture2DOES")
        else { throw EyeGLError("no glEGLImageTargetTexture2DOES") }
        imageTarget = unsafeBitCast(proc, to: ImageTargetTexture2D.self)

        progY = try buildProgram(fragment: Self.fragY)
        progUV = try buildProgram(fragment: Self.fragUV)
        prog444 = try buildProgram(fragment: Self.frag444)
        srcSizeLocY = glGetUniformLocation(progY, "srcSize")
        srcSizeLocUV = glGetUniformLocation(progUV, "srcSize")
        srcSizeLoc444 = glGetUniformLocation(prog444, "srcSize")
    }

    // MARK: - Shaders

    // Fullscreen triangle from gl_VertexID; no buffers, no attribs
    // (compatibility-profile context — the probe got Mesa 4.6 compat).
    private static let vertex = """
    #version 130
    void main() {
        vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
        gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    }
    """

    // BT.709 limited-range luma from full-range RGB.
    private static let fragY = """
    #version 130
    uniform sampler2D src;
    uniform vec2 srcSize;
    void main() {
        vec3 c = texture(src, gl_FragCoord.xy / srcSize).rgb;
        float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
        gl_FragColor = vec4(16.0 / 255.0 + y * (219.0 / 255.0), 0.0, 0.0, 1.0);
    }
    """

    // BT.709 limited-range chroma at half resolution; LINEAR sampling
    // at the 2x2 center gives the downsample average for free.
    private static let fragUV = """
    #version 130
    uniform sampler2D src;
    uniform vec2 srcSize;
    void main() {
        vec3 c = texture(src, gl_FragCoord.xy * 2.0 / srcSize).rgb;
        float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float u = (c.b - y) / 1.8556;
        float v = (c.r - y) / 1.5748;
        gl_FragColor = vec4(128.0 / 255.0 + u * (224.0 / 255.0),
                            128.0 / 255.0 + v * (224.0 / 255.0), 0.0, 1.0);
    }
    """

    // BT.709 limited-range Y, U, V — all three at full resolution in
    // one pass, for the packed AYUV plane. The plane's memory bytes
    // are [V, U, Y, A]; imported as DRM ARGB8888 its bytes read
    // [B, G, R, A], so writing vec4(y, u, v, 1) lands Y in byte 2,
    // U in byte 1, V in byte 0 — exactly AYUV.
    private static let frag444 = """
    #version 130
    uniform sampler2D src;
    uniform vec2 srcSize;
    void main() {
        vec3 c = texture(src, gl_FragCoord.xy / srcSize).rgb;
        float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float u = (c.b - y) / 1.8556;
        float v = (c.r - y) / 1.5748;
        gl_FragColor = vec4(16.0 / 255.0 + y * (219.0 / 255.0),
                            128.0 / 255.0 + u * (224.0 / 255.0),
                            128.0 / 255.0 + v * (224.0 / 255.0), 1.0);
    }
    """

    private func compile(_ type: GLenum, _ source: String) throws -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { cs in
            var ptr: UnsafePointer<GLchar>? = cs
            glShaderSource(shader, 1, &ptr, nil)
        }
        glCompileShader(shader)
        var ok: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &ok)
        guard ok == GL_TRUE else {
            var log = [GLchar](repeating: 0, count: 1024)
            glGetShaderInfoLog(shader, 1024, nil, &log)
            let text = String(decoding: log.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            }, as: UTF8.self)
            throw EyeGLError("shader compile: \(text)")
        }
        return shader
    }

    private func buildProgram(fragment: String) throws -> GLuint {
        let vs = try compile(GLenum(GL_VERTEX_SHADER), Self.vertex)
        let fs = try compile(GLenum(GL_FRAGMENT_SHADER), fragment)
        let prog = glCreateProgram()
        glAttachShader(prog, vs)
        glAttachShader(prog, fs)
        glLinkProgram(prog)
        var ok: GLint = 0
        glGetProgramiv(prog, GLenum(GL_LINK_STATUS), &ok)
        guard ok == GL_TRUE else {
            var log = [GLchar](repeating: 0, count: 1024)
            glGetProgramInfoLog(prog, 1024, nil, &log)
            let text = String(decoding: log.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            }, as: UTF8.self)
            throw EyeGLError("program link: \(text)")
        }
        glDeleteShader(vs)
        glDeleteShader(fs)
        return prog
    }

    // MARK: - dmabuf import

    /// Import a dmabuf as an EGLImage-backed 2D texture, modifier-aware.
    public func importTexture(
        width: Int32, height: Int32, fourcc: UInt32, modifier: UInt64,
        planes: [(fd: Int32, offset: UInt32, pitch: UInt32)]
    ) throws -> ImportedTexture {
        var attribs: [EGLAttrib] = [
            EGLAttrib(EGL_WIDTH), EGLAttrib(width),
            EGLAttrib(EGL_HEIGHT), EGLAttrib(height),
            EGLAttrib(EGL_LINUX_DRM_FOURCC_EXT), EGLAttrib(fourcc),
        ]
        for (i, plane) in planes.enumerated() {
            attribs += [
                EGLAttrib(planeFdAttrs[i]), EGLAttrib(plane.fd),
                EGLAttrib(planeOffsetAttrs[i]), EGLAttrib(plane.offset),
                EGLAttrib(planePitchAttrs[i]), EGLAttrib(plane.pitch),
                EGLAttrib(planeModLoAttrs[i]),
                EGLAttrib(modifier & 0xffff_ffff),
                EGLAttrib(planeModHiAttrs[i]),
                EGLAttrib(modifier >> 32),
            ]
        }
        attribs.append(EGLAttrib(EGL_NONE))
        let image = attribs.withUnsafeBufferPointer {
            eglCreateImage(
                display, nil, EGLenum(EGL_LINUX_DMA_BUF_EXT), nil,
                $0.baseAddress)
        }
        guard image != nil else {
            throw EyeGLError("eglCreateImage failed: "
                + "0x\(String(eglGetError(), radix: 16)) fourcc=\(fourcc)")
        }
        var tex: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GLenum(GL_TEXTURE_2D), tex)
        glTexParameteri(
            GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(
            GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(
            GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S),
            GL_CLAMP_TO_EDGE)
        glTexParameteri(
            GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T),
            GL_CLAMP_TO_EDGE)
        imageTarget(GLenum(GL_TEXTURE_2D), image)
        let err = glGetError()
        guard err == GLenum(GL_NO_ERROR) else {
            glDeleteTextures(1, &tex)
            eglDestroyImage(display, image)
            throw EyeGLError(
                "image→texture failed: 0x\(String(err, radix: 16))")
        }
        return ImportedTexture(image: image, texture: tex)
    }

    public func destroy(_ imported: inout ImportedTexture) {
        var tex = imported.texture
        if tex != 0 { glDeleteTextures(1, &tex) }
        if let image = imported.image { eglDestroyImage(display, image) }
        imported = ImportedTexture(image: nil, texture: 0)
    }

    /// Full teardown of an NV12 target (the chroma re-open path):
    /// FBOs, textures, EGL images — the exported dmabuf fds were
    /// closed at import time.
    public func destroy(_ target: inout NV12Target) {
        var fbos = [target.fboY, target.fboUV]
        glDeleteFramebuffers(2, &fbos)
        destroy(&target.y)
        destroy(&target.uv)
    }

    public func destroy(_ target: inout AyuvTarget) {
        var fbo = target.fbo
        glDeleteFramebuffers(1, &fbo)
        destroy(&target.plane)
    }

    // MARK: - NV12 render target

    private func attach(_ tex: GLuint) throws -> GLuint {
        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_2D), tex, 0)
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            throw EyeGLError(
                "FBO incomplete: 0x\(String(status, radix: 16))")
        }
        return fbo
    }

    /// Wrap an exported NV12 surface (two separate-layer planes) as
    /// FBO render targets.
    public func makeNV12Target(
        width: Int32, height: Int32,
        yFourcc: UInt32, yModifier: UInt64,
        yPlane: (fd: Int32, offset: UInt32, pitch: UInt32),
        uvFourcc: UInt32, uvModifier: UInt64,
        uvPlane: (fd: Int32, offset: UInt32, pitch: UInt32)
    ) throws -> NV12Target {
        let y = try importTexture(
            width: width, height: height, fourcc: yFourcc,
            modifier: yModifier, planes: [yPlane])
        let uv = try importTexture(
            width: width / 2, height: height / 2, fourcc: uvFourcc,
            modifier: uvModifier, planes: [uvPlane])
        let fboY = try attach(y.texture)
        let fboUV = try attach(uv.texture)
        return NV12Target(
            y: y, uv: uv, fboY: fboY, fboUV: fboUV,
            width: width, height: height)
    }

    /// Wrap an exported packed AYUV surface (one layer) as an FBO
    /// render target, imported as ARGB8888 (byte-identical layout —
    /// see frag444 for the channel mapping).
    public func makeAyuvTarget(
        width: Int32, height: Int32, modifier: UInt64,
        plane: (fd: Int32, offset: UInt32, pitch: UInt32)
    ) throws -> AyuvTarget {
        let argb8888: UInt32 = 0x3432_5241 // DRM_FORMAT_ARGB8888 'AR24'
        let imported = try importTexture(
            width: width, height: height, fourcc: argb8888,
            modifier: modifier, planes: [plane])
        let fbo = try attach(imported.texture)
        return AyuvTarget(
            plane: imported, fbo: fbo, width: width, height: height)
    }

    // MARK: - The blit

    /// RGB scanout → NV12 target, two passes, then a full GPU sync so
    /// the encoder never reads a half-written surface (prototype-grade
    /// sync; the production organ graduates to fences).
    public func blit(source: ImportedTexture, srcWidth: Int32, srcHeight: Int32,
              into target: NV12Target) {
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), source.texture)

        glUseProgram(progY)
        glUniform2f(srcSizeLocY, GLfloat(srcWidth), GLfloat(srcHeight))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.fboY)
        glViewport(0, 0, target.width, target.height)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)

        glUseProgram(progUV)
        glUniform2f(srcSizeLocUV, GLfloat(srcWidth), GLfloat(srcHeight))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.fboUV)
        glViewport(0, 0, target.width / 2, target.height / 2)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)

        glFinish()
    }

    /// RGB scanout → packed AYUV target, one pass at full resolution
    /// (the 4:4:4 tier keeps every chroma sample), same prototype
    /// glFinish sync as the NV12 blit.
    public func blit444(
        source: ImportedTexture, srcWidth: Int32, srcHeight: Int32,
        into target: AyuvTarget
    ) {
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), source.texture)

        glUseProgram(prog444)
        glUniform2f(srcSizeLoc444, GLfloat(srcWidth), GLfloat(srcHeight))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.fbo)
        glViewport(0, 0, target.width, target.height)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)

        glFinish()
    }
}

#endif
