// Termination signals: SIGINT/SIGTERM exit through the same door as a
// completed run, so the audio-routing restore and the typed 0x0A teardown
// both happen. The handler only raises a flag; the handshake wait and the
// capture loop poll it. A second signal while that teardown hangs exits at
// once. kill -9 is AudioWire.sweepLeftoverRouting's job.
//
// Outside main.swift on purpose: top-level code gives its globals special
// isolation, and the flag must be a plain (async-signal-writable) global.

import Foundation

/// sig_atomic_t-style flag: the handler writes one word; the handshake and
/// capture loops poll it. nonisolated(unsafe) is honest — one async writer,
/// polling readers, no ordering requirement beyond eventually.
nonisolated(unsafe) var lyteTerminationRequested: Int32 = 0

/// Arms SIGINT/SIGTERM → the graceful-exit flag; a second one exits at
/// once with the shell's 128 + signal status, so a supervisor reads
/// SIGTERM (143) as SIGTERM and SIGINT (130) as SIGINT.
func lyteInstallTerminationHandlers() {
    let handler: @convention(c) (Int32) -> Void = { signal in
        if lyteTerminationRequested != 0 { _exit(128 + signal) }
        lyteTerminationRequested = 1
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
}

/// A reader that goes away (a hand-run host piped through tee or ssh)
/// makes the next write fail with EPIPE instead of killing the process.
/// libdbus sets the same disposition, but only when a connection exists.
func lyteIgnoreBrokenPipes() {
    signal(SIGPIPE, SIG_IGN)
}
