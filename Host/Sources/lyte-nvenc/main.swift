// lyte-nvenc (E6a milestone 1): the NVENC-native probe — Swift talks
// to libnvidia-encode directly, no libavcodec anywhere in the path.
// Proves the two levers that kill the vendored no-reset patch at the
// root:
//
//   1. The SDK writes its OWN headers: an infinite-GOP HEVC stream
//      whose only IDR is the demanded opening one (repeatSPSPPS off
//      the table — headers ride the first packet, the wire's
//      stream-startability contract).
//   2. NvEncReconfigureEncoder changes the rate MID-STREAM with
//      resetEncoder=0, forceIDR=0 — the very thing the vendor patch
//      exists to fake — and the stream keeps decoding.
//
// Usage: lyte-nvenc [out.h265] [frames] [width] [height]
// Gates: exactly 1 IDR across the run; reconfigure at the midpoint
// returns success and mints NO IDR; the file decodes on the Mac via
// `swift run lyte-cli decode-probe` (the E1 gate).

#if os(Linux)

import LyteIO
import CCuda
import CNvEnc
import Foundation
import Glibc

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/nvenc-probe.h265"
let frameCount = CommandLine.arguments.count > 2
    ? Int(CommandLine.arguments[2]) ?? 120 : 120
let width = CommandLine.arguments.count > 3
    ? Int32(CommandLine.arguments[3]) ?? 1920 : 1920
let height = CommandLine.arguments.count > 4
    ? Int32(CommandLine.arguments[4]) ?? 1080 : 1080

func fail(_ message: String) -> Never {
    print("nvenc-probe: FAIL — \(message)")
    exit(1)
}

func check(_ status: NVENCSTATUS, _ what: String,
           lastError: (() -> String)? = nil) {
    guard status == NV_ENC_SUCCESS else {
        let detail = lastError.map { " — \($0())" } ?? ""
        fail("\(what): NVENCSTATUS \(status.rawValue)\(detail)")
    }
}

// MARK: CUDA context (the session's device handle; frames ride
// NVENC's own system-memory input buffers, so this is ALL the CUDA
// the probe needs)

guard cuInit(0) == 0 else { fail("cuInit — is nvidia loaded?") }
var driverVersion: Int32 = 0
_ = cuDriverGetVersion(&driverVersion)
var deviceCount: Int32 = 0
guard cuDeviceGetCount(&deviceCount) == 0, deviceCount > 0 else {
    fail("no CUDA devices")
}
var device: CUdevice = 0
guard cuDeviceGet(&device, 0) == 0 else { fail("cuDeviceGet(0)") }
var nameBytes = [CChar](repeating: 0, count: 128)
_ = cuDeviceGetName(&nameBytes, 128, device)
var context: CUcontext?
guard cuCtxCreate_v2(&context, 0, device) == 0, let cudaContext = context
else { fail("cuCtxCreate") }
defer { _ = cuCtxDestroy_v2(cudaContext) }

var maxVersion: UInt32 = 0
check(NvEncodeAPIGetMaxSupportedVersion(&maxVersion),
      "NvEncodeAPIGetMaxSupportedVersion")
let deviceName = String(
    decoding: nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
    as: UTF8.self)
print("nvenc-probe: \(deviceName) — driver CUDA "
    + "\(driverVersion / 1000).\(driverVersion % 1000 / 10), NVENC API "
    + "\(maxVersion >> 4).\(maxVersion & 0xF) (header "
    + "\(LYTE_NVENCAPI_VERSION & 0xFF).\(LYTE_NVENCAPI_VERSION >> 24))")
guard maxVersion >= (LYTE_NVENCAPI_VERSION & 0xFF) << 4
        | (LYTE_NVENCAPI_VERSION >> 24) else {
    fail("driver NVENC API older than the vendored 12.2 header")
}

// MARK: The function table + session

var api = NV_ENCODE_API_FUNCTION_LIST()
api.version = LYTE_NV_ENCODE_API_FUNCTION_LIST_VER
check(NvEncodeAPICreateInstance(&api), "NvEncodeAPICreateInstance")

var open = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS()
open.version = LYTE_NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER
open.deviceType = NV_ENC_DEVICE_TYPE_CUDA
open.device = UnsafeMutableRawPointer(cudaContext)
open.apiVersion = LYTE_NVENCAPI_VERSION
var encoderRaw: UnsafeMutableRawPointer?
check(api.nvEncOpenEncodeSessionEx!(&open, &encoderRaw),
      "nvEncOpenEncodeSessionEx")
guard let encoder = encoderRaw else { fail("nil encoder handle") }
let lastError = { String(cString: api.nvEncGetLastErrorString!(encoder)!) }
defer { _ = api.nvEncDestroyEncoder!(encoder) }

// MARK: Config — the wire's encode discipline, spoken natively

var preset = NV_ENC_PRESET_CONFIG()
preset.version = LYTE_NV_ENC_PRESET_CONFIG_VER
preset.presetCfg.version = LYTE_NV_ENC_CONFIG_VER
check(api.nvEncGetEncodePresetConfigEx!(
        encoder, NV_ENC_CODEC_HEVC_GUID, NV_ENC_PRESET_P1_GUID,
        NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset),
      "nvEncGetEncodePresetConfigEx", lastError: lastError)

var config = preset.presetCfg
let infiniteGop: UInt32 = 0xFFFF_FFFF // NVENC_INFINITE_GOPLENGTH
config.gopLength = infiniteGop
config.frameIntervalP = 1 // IPPP…, zero B-frames (latency law)
config.encodeCodecConfig.hevcConfig.idrPeriod = infiniteGop
// Headers ride the FIRST packet only (OUTPUT_SPSPPS on the opening
// IDR) — the wire's stream-startability contract, not in-band repeat.
config.encodeCodecConfig.hevcConfig.repeatSPSPPS = 0
config.rcParams.rateControlMode = NV_ENC_PARAMS_RC_VBR
config.rcParams.averageBitRate = 35_000_000
config.rcParams.maxBitRate = 50_000_000
// 4 frame periods at 60 fps — the E1 VBV posture.
config.rcParams.vbvBufferSize = 50_000_000 / 15

var initParams = NV_ENC_INITIALIZE_PARAMS()
initParams.version = LYTE_NV_ENC_INITIALIZE_PARAMS_VER
initParams.encodeGUID = NV_ENC_CODEC_HEVC_GUID
initParams.presetGUID = NV_ENC_PRESET_P1_GUID
initParams.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY
initParams.encodeWidth = UInt32(width)
initParams.encodeHeight = UInt32(height)
initParams.darWidth = UInt32(width)
initParams.darHeight = UInt32(height)
initParams.frameRateNum = 60
initParams.frameRateDen = 1
initParams.enableEncodeAsync = 0 // Linux: synchronous
initParams.enablePTD = 1         // the encoder picks picture types
withUnsafeMutablePointer(to: &config) { configPtr in
    initParams.encodeConfig = configPtr
    check(api.nvEncInitializeEncoder!(encoder, &initParams),
          "nvEncInitializeEncoder", lastError: lastError)
}

// MARK: Buffers (sync mode: one in, one out, reused)

var createInput = NV_ENC_CREATE_INPUT_BUFFER()
createInput.version = LYTE_NV_ENC_CREATE_INPUT_BUFFER_VER
createInput.width = UInt32(width)
createInput.height = UInt32(height)
createInput.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12
check(api.nvEncCreateInputBuffer!(encoder, &createInput),
      "nvEncCreateInputBuffer", lastError: lastError)
let inputBuffer = createInput.inputBuffer
defer { _ = api.nvEncDestroyInputBuffer!(encoder, inputBuffer) }

var createBitstream = NV_ENC_CREATE_BITSTREAM_BUFFER()
createBitstream.version = LYTE_NV_ENC_CREATE_BITSTREAM_BUFFER_VER
check(api.nvEncCreateBitstreamBuffer!(encoder, &createBitstream),
      "nvEncCreateBitstreamBuffer", lastError: lastError)
let bitstreamBuffer = createBitstream.bitstreamBuffer
defer { _ = api.nvEncDestroyBitstreamBuffer!(encoder, bitstreamBuffer) }

// MARK: The run — moving synthetic NV12, reconfigure at the midpoint

func fillFrame(_ base: UnsafeMutableRawPointer, pitch: Int, frame: Int) {
    let luma = base.assumingMemoryBound(to: UInt8.self)
    let w = Int(width), h = Int(height)
    for y in 0..<h {
        let row = luma.advanced(by: y * pitch)
        for x in 0..<w {
            row[x] = UInt8((x &+ y &+ frame &* 3) & 0xFF)
        }
    }
    let chroma = luma.advanced(by: pitch * h)
    let bar = (frame &* 7) % w
    for y in 0..<(h / 2) {
        let row = chroma.advanced(by: y * pitch)
        for x in 0..<(w / 2) {
            let inBar = abs(x * 2 - bar) < 64
            row[x * 2] = inBar ? 90 : 128      // U
            row[x * 2 + 1] = inBar ? 200 : 128 // V
        }
    }
}

var out = Data()
var idrFrames: [Int] = []
var intraFrames = 0
var encodeNanos: [UInt64] = []
let reconfigureAt = frameCount / 2
var reconfigured = false

for frame in 0..<frameCount {
    // The midpoint lever: halve the envelope, zero reset, zero IDR —
    // the exact call the vendored patch fakes in libavcodec.
    if frame == reconfigureAt {
        config.rcParams.averageBitRate = 18_000_000
        config.rcParams.maxBitRate = 25_000_000
        config.rcParams.vbvBufferSize = 25_000_000 / 15
        var reconfigure = NV_ENC_RECONFIGURE_PARAMS()
        reconfigure.version = LYTE_NV_ENC_RECONFIGURE_PARAMS_VER
        reconfigure.reInitEncodeParams = initParams
        withUnsafeMutablePointer(to: &config) { configPtr in
            reconfigure.reInitEncodeParams.encodeConfig = configPtr
            reconfigure.resetEncoder = 0
            reconfigure.forceIDR = 0
            check(api.nvEncReconfigureEncoder!(encoder, &reconfigure),
                  "nvEncReconfigureEncoder", lastError: lastError)
        }
        reconfigured = true
        print("nvenc-probe: reconfigured 35→18 Mbps at frame \(frame) "
            + "(resetEncoder=0, forceIDR=0)")
    }

    var lockInput = NV_ENC_LOCK_INPUT_BUFFER()
    lockInput.version = LYTE_NV_ENC_LOCK_INPUT_BUFFER_VER
    lockInput.inputBuffer = inputBuffer
    check(api.nvEncLockInputBuffer!(encoder, &lockInput),
          "nvEncLockInputBuffer", lastError: lastError)
    fillFrame(lockInput.bufferDataPtr!,
              pitch: Int(lockInput.pitch), frame: frame)
    check(api.nvEncUnlockInputBuffer!(encoder, inputBuffer),
          "nvEncUnlockInputBuffer", lastError: lastError)

    var pic = NV_ENC_PIC_PARAMS()
    pic.version = LYTE_NV_ENC_PIC_PARAMS_VER
    pic.inputWidth = UInt32(width)
    pic.inputHeight = UInt32(height)
    pic.inputPitch = lockInput.pitch
    pic.inputBuffer = inputBuffer
    pic.outputBitstream = bitstreamBuffer
    pic.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12
    pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME
    pic.inputTimeStamp = UInt64(frame)
    if frame == 0 {
        // The ONE demanded IDR, headers attached — 0x0302's shape.
        pic.encodePicFlags =
            NV_ENC_PIC_FLAG_FORCEIDR.rawValue
                | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS.rawValue
    }
    let t0 = SystemMonotonicClock.nowNanoseconds
    check(api.nvEncEncodePicture!(encoder, &pic),
          "nvEncEncodePicture frame \(frame)", lastError: lastError)
    encodeNanos.append(SystemMonotonicClock.nowNanoseconds - t0)

    var lockBitstream = NV_ENC_LOCK_BITSTREAM()
    lockBitstream.version = LYTE_NV_ENC_LOCK_BITSTREAM_VER
    lockBitstream.outputBitstream = bitstreamBuffer
    check(api.nvEncLockBitstream!(encoder, &lockBitstream),
          "nvEncLockBitstream", lastError: lastError)
    out.append(Data(bytes: lockBitstream.bitstreamBufferPtr!,
                    count: Int(lockBitstream.bitstreamSizeInBytes)))
    switch lockBitstream.pictureType {
    case NV_ENC_PIC_TYPE_IDR: idrFrames.append(frame)
    case NV_ENC_PIC_TYPE_I: intraFrames += 1
    default: break
    }
    check(api.nvEncUnlockBitstream!(encoder, bitstreamBuffer),
          "nvEncUnlockBitstream", lastError: lastError)
}

// MARK: Books + gates

try out.write(to: URL(fileURLWithPath: outPath))
let sorted = encodeNanos.sorted()
let p50 = Double(sorted[sorted.count / 2]) / 1e6
let p99 = Double(sorted[min(sorted.count - 1,
                            sorted.count * 99 / 100)]) / 1e6
print("nvenc-probe: \(frameCount) frames \(width)x\(height) → "
    + "\(out.count) B (\(outPath)); encode p50 "
    + String(format: "%.2f", p50) + " ms / p99 "
    + String(format: "%.2f", p99) + " ms")
print("nvenc-probe: IDRs at \(idrFrames), spontaneous intras "
    + "\(intraFrames), reconfigured=\(reconfigured)")

guard idrFrames == [0] else {
    fail("IDR discipline broken — expected exactly [0], got \(idrFrames)"
        + (reconfigured && idrFrames.count > 1
            ? " (the reconfigure minted one?)" : ""))
}
guard reconfigured else { fail("reconfigure never ran") }
print("nvenc-probe: PASS — one demanded IDR, mid-stream rate move "
    + "with zero reset and zero IDR. The vendor patch's job, done "
    + "by the front door.")

#endif
