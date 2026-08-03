import CoreMedia
import Foundation
import LyteWire

// CoreMedia adapter only. Queue and recovery policy live in LyteCore and
// never see CMSampleBuffer, attachments, or the host-clock timebase.
public enum VideoSampleTiming {
    public static func attachBuildTelemetry(
        to sample: CMSampleBuffer,
        sampleBuildMicroseconds: UInt64,
        assemblyLockHoldMicroseconds: UInt64
    ) {
        let buildKey = "org.lyte.video.sample-build-us" as CFString
        let lockKey = "org.lyte.video.assembly-lock-us" as CFString
        CMSetAttachment(
            sample, key: buildKey,
            value: NSNumber(value: sampleBuildMicroseconds),
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        CMSetAttachment(
            sample, key: lockKey,
            value: NSNumber(value: assemblyLockHoldMicroseconds),
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    }

    public static func buildTelemetry(
        from sample: CMSampleBuffer
    ) -> VideoFrameBuildTelemetry? {
        let buildKey = "org.lyte.video.sample-build-us" as CFString
        let lockKey = "org.lyte.video.assembly-lock-us" as CFString
        guard let build = CMGetAttachment(
            sample, key: buildKey, attachmentModeOut: nil) as? NSNumber,
              let hold = CMGetAttachment(
            sample, key: lockKey, attachmentModeOut: nil) as? NSNumber
        else { return nil }
        return VideoFrameBuildTelemetry(
            frame: 0,
            assemblyLockHoldMicroseconds: hold.uint64Value,
            sampleBuildMicroseconds: build.uint64Value)
    }

    /// Re-stamps a ready sample into the local CM host-clock domain.
    public static func retimed(
        _ sample: CMSampleBuffer,
        presentationMicroseconds: UInt64
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: Int64(bitPattern: presentationMicroseconds),
                timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
