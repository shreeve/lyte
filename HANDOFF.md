# Lyte — handoff

*Live resume point, 2026-09-26. Git owns completed history.*

## Tip

- `main` @ **#253**: the third revamp pass (#252) and the decode-stall fix
  (#253); user-visible changes in [CHANGELOG.md](CHANGELOG.md) "Unreleased". 0.6.0 is the last
  release (`v0.6.0`; the enclosure is EdDSA-signed, the feed is not); cask
  shreeve/homebrew-tap#5 is open.
- Gates (`-warnings-as-errors`): Wire 468 (467 wasm32), Common 113, Host
  383, Client 505, SystemTests 12, Browser 38 (+10 page); pup Host 451,
  Client 156, Browser 38.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`, advertised on `wlp0s20f3`).
- `lyte-host.service` serves UDP **41151** from `versions/8d5e83fcc831`: the
  **soak** of local branch `experiment/wifi-resilience` (this Mac only; Wi-Fi
  rate recovery, see its CHANGELOG note). The #253 host (pre-soak) is
  `bb4ce518dd2f`: `cd ~/src/lyte-host && ./Scripts/deploy-host.sh
  --restart ~/.local/share/lyte/versions/bb4ce518dd2f`. It logs `direct: capturing /dev/dri/card1`.
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: `~/.config/lyte-host/`, `~/lyte-revamp-backup/`, `~/lyte-migration-*`.
- **This Mac is paired**; `.build/Lyte.app` (built from the experiment)
  streams from pup with keyboard and mouse.

## Next

1. Merge shreeve/homebrew-tap#5; then cut a release from `main`
   ([docs/RELEASING.md](docs/RELEASING.md)), install it, grant Local
   Network once, and check ⌘-letter as Ctrl (⌘⇧C/⌘⇧V in a Linux terminal),
   Secure Keyboard Entry, last-seen host rows, clipboard both ways, roam on
   `sudo systemctl restart lyte-host`; then
   `LYTE_BENCHMARK_HOST=10.0.0.249 Scripts/benchmark-app.sh motion`.
2. Next pass: the daily-driver browser client ([TODO.md](TODO.md#browser)).
3. Owner decisions in [TODO.md](TODO.md): signing the update feed, netem
   reordering, enforcing the gates, pairing enforcement before 1.0.
