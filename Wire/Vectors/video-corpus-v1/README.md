# video-corpus-v1 — the W2 golden HEVC corpus

Real Annex-B HEVC access units captured from the H0a file-output host
(`lyte-host` on pop: portal ScreenCast → PipeWire → hevc_nvenc, the plain
non-ratchet path), published as first-class W2 artifacts (master plan
§4.12): client CL-2 and host HS-5 code against these frames and the
packetize/assembly vectors in `../video-v1.json` before either end sends
a live datagram.

**Freeze policy** is the vector policy: committed corpus files never
change. `video-v1.json` pins each referenced file by sha256 and the test
suites fail loudly on drift. New material goes in a `video-corpus-v2/`.

## Provenance

Source capture: `/tmp/lyte-plain.hevc` on pop (2026-07-20, 1547155 bytes,
sha256 `c50da8279b45d76645a88dcb883514d0a91cf510178faaf4b24f5375c1ebdc53`,
301 access units, 1080p60 hevc_nvenc, frame 0 forced IDR, the rest
P-frames). Frames were split on access-unit boundaries by NAL walking
(`AnnexBStream.accessUnitRanges`): a new access unit starts at the first
leading NAL (VPS/SPS/PPS/AUD/prefix-SEI or VCL) after the previous unit's
VCL NAL. Splits land on start-code boundaries, so concatenating a
contiguous run of frames reproduces the capture's bytes exactly.

## Files

`frame-000` … `frame-009` are the capture's first ten access units —
**contiguous**, so their in-order concatenation is a decodable stream
(IDR first). `frame-10x-p-small` are steady-state small P-frames from
later in the capture (access units 186/188/190) — packetization fixtures
for the k=4 bucket, *not* part of the decodable prefix.

| file | AU # | bytes | NALs |
|---|---|---|---|
| frame-000-idr.annexb | 0 | 18400 | VPS SPS PPS PREFIX_SEI IDR_W_RADL |
| frame-001-p.annexb | 1 | 20786 | PREFIX_SEI TRAIL_R (largest frame) |
| frame-002-p.annexb | 2 | 20338 | PREFIX_SEI TRAIL_R |
| frame-003-p.annexb | 3 | 20378 | PREFIX_SEI TRAIL_R |
| frame-004-p.annexb | 4 | 18211 | PREFIX_SEI TRAIL_R |
| frame-005-p.annexb | 5 | 17321 | PREFIX_SEI TRAIL_R |
| frame-006-p.annexb | 6 | 16719 | PREFIX_SEI TRAIL_R |
| frame-007-p.annexb | 7 | 17019 | PREFIX_SEI TRAIL_R |
| frame-008-p.annexb | 8 | 15614 | PREFIX_SEI TRAIL_R |
| frame-009-p.annexb | 9 | 14359 | PREFIX_SEI TRAIL_R |
| frame-100-p-small.annexb | 186 | 4367 | PREFIX_SEI TRAIL_R |
| frame-101-p-small.annexb | 188 | 4367 | PREFIX_SEI TRAIL_R |
| frame-102-p-small.annexb | 190 | 4367 | PREFIX_SEI TRAIL_R |

Sizes span the geometry ladder: the small P-frames packetize at k=4
(3…8 bucket), the large frames at k=17…19 (9…32 bucket), covering the
shapes live traffic produces at both regimes.

## Verification

- `VideoCorpusTests` (both platforms): every file is frame-shaped, one
  access unit, round-trips packetizer → damage → assembler byte-exact at
  the parity-loss limit under both regimes; the 000–009 prefix
  reassembles as one byte-exact stream through a single channel with
  interleaving and loss.
- `VideoVectorFileTests`: the sha256 pins in `../video-v1.json`.
- Decode evidence (W-G3): `swift run lyte-wire-vectorgen video-roundtrip`
  on the reassembled prefix, then `ffmpeg -f null -` on pop — clean
  decode, zero errors. The same harness round-trips the full 301-frame
  source capture byte-exact under ~21% injected loss.
