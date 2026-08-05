# Opus source provenance

Lyte vendors the generic floating-point production sources from the official
Xiph Opus 1.6.1 release dated 2026-01-14.

- Release: <https://opus-codec.org/release/stable/2026/01/14/libopus-1_6_1.html>
- Archive: <https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz>
- Archive SHA-256: `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`
- License: BSD 3-Clause; the verbatim notice is
  [`Upstream/opus-1.6.1/COPYING`](Upstream/opus-1.6.1/COPYING).

The committed subset is the union of `OPUS_SOURCES`, `OPUS_SOURCES_FLOAT`,
`CELT_SOURCES`, `SILK_SOURCES`, and `SILK_SOURCES_FLOAT` from the release's
four `*_sources.mk` lists, plus their private headers and all six public
headers. Tests, tools, custom modes, DRED/OSCE/deep-PLC machinery, generated
build files, and architecture-specific RTCD/SIMD/assembly sources are omitted.
SwiftPM defines `OPUS_BUILD`, `USE_ALLOCA`, `DISABLE_DEBUG_FLOAT`, and the
pinned package version. The generic scalar path is deliberate: one source leaf
must first prove itself on macOS and Linux before optional acceleration earns a
separate change.

Given a separately obtained copy of the official archive, reproduce the
byte-for-byte provenance proof with:

```sh
Scripts/verify-opus-upstream.sh /path/to/opus-1.6.1.tar.gz
```

The verifier checks the archive digest first, then compares every one of the
234 committed upstream files and six public-header copies with that archive.
