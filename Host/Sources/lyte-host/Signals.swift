// Termination signals: SIGINT/SIGTERM exit through the same door as a
// completed run, so the audio-routing restore and the typed 0x0A teardown
// both happen. The handler only raises a flag; the handshake wait and the
// capture loop poll it. kill -9 is AudioWire.sweepLeftoverRouting's job.
//
// Outside main.swift on purpose: top-level code gives its globals special
// isolation, and the flag must be a plain (async-signal-writable) global.

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
