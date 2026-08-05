// Termination signals (HS-18): a SIGINT/SIGTERM must exit through the
// same door as a completed run, so the audio-routing restore (the
// virtual sink's default-sink switch put back) and the typed 0x0A
// teardown both happen. The handler only raises a flag; the pre-session
// handshake wait and DirectEyeLeg's capture tick read it and return through
// their normal cleanup paths. kill -9 bypasses all of this by
// definition; that is what AudioWire.sweepLeftoverRouting's
// next-start sweep is for.
//
// This lives OUTSIDE main.swift on purpose: a file with top-level
// code gives its globals special isolation, and the flag must be a
// plain (async-signal-writable) global.

import Foundation

/// sig_atomic_t-style flag: the handler writes one word; the handshake and
/// capture loops poll it. nonisolated(unsafe) is honest — one async writer,
/// polling readers, no ordering requirement beyond eventually.
nonisolated(unsafe) var lyteTerminationRequested: Int32 = 0

/// Arms SIGINT/SIGTERM → the graceful-exit flag.
func lyteInstallTerminationHandlers() {
    let handler: @convention(c) (Int32) -> Void = { _ in
        lyteTerminationRequested = 1
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
}
