# Lyte — handoff

*Live resume point, 2026-09-26. Git owns completed history.*

## Tip

- `main` @ **#251**: 0.6.0 released (`v0.6.0`, notarized; the enclosure is
  EdDSA-signed, the feed is not); cask shreeve/homebrew-tap#5 is open.
- Local branch **`revamp`** (unpushed): the third revamp pass, "shrink and
  fix", from `main` @ 0a6f66f. Both gates pass on it: Wire 468 (467
  wasm32), Common 113, Host 383, Client 505, SystemTests 12, Browser 38
  (+10 page); pup Host 451, Client 156, Browser 38. User-visible changes:
  [CHANGELOG.md](CHANGELOG.md) "Unreleased".

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`, advertised on `wlp0s20f3`).
- `lyte-host.service` serves UDP **41151**: `~/.local/bin/lyte-host` →
  `versions/bb4ce518dd2f` (`revamp`'s host; it logs `direct: capturing
  /dev/dri/card1 (i915, discovered)`). Previous `7188d8b60f68` (#248, `main`)
  is kept: `cd ~/src/lyte-host && ./Scripts/deploy-host.sh --rollback
  --restart`. `host.conf` passes only `--wire-listen 41151
  --clipboard=images --advertise-interface wlp0s20f3`.
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: `~/.config/lyte-host/`, `~/lyte-revamp-backup/`, `~/lyte-migration-*`.
- **This Mac is paired**, but `Lyte.app` lacks the **Local Network** grant
  (`Local network prohibited`); `lyte-cli wire-view 0 --host 10.0.0.249
  --host-port 41151` works from a terminal.

## Next

1. Owner: review `revamp` and land it as one PR (gates on the landing
   commit); if it is not landed, roll pup back (above).
2. Merge shreeve/homebrew-tap#5; then cut a release from `main`
   ([docs/RELEASING.md](docs/RELEASING.md)), install it, grant Local
   Network once, and check ⌘-letter as Ctrl (⌘⇧C/⌘⇧V in a Linux terminal),
   Secure Keyboard Entry, last-seen host rows, clipboard both ways, roam on
   `sudo systemctl restart lyte-host`; then
   `LYTE_BENCHMARK_HOST=10.0.0.249 Scripts/benchmark-app.sh motion`.
3. Next pass: the daily-driver browser client ([TODO.md](TODO.md#browser)).
