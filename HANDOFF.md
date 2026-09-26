# Lyte — handoff

*Live resume point, 2026-09-26. Git owns completed history.*

## Tip

- `main` @ **#257**. **0.7.0 is released** (`v0.7.0`, notarized; the
  enclosure is EdDSA-signed, the feed is not): the third revamp pass,
  the decode-stall fix, keyframe causes, timestamped `host.log`, Wi-Fi
  rate recovery and the one-line installer ([CHANGELOG.md](CHANGELOG.md)).
  Install: `brew install --cask shreeve/tap/lyte` (tap #9 is 0.7.0) or
  `Scripts/install.sh` via curl ([README.md](README.md)); Sparkle updates.
- Gates (`-warnings-as-errors`): Wire 469 (468 wasm32), Common 113, Host
  391, Client 510, SystemTests 12, Browser 38 (+10 page); pup Host 459,
  Client 156, Browser 38.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`, advertised on `wlp0s20f3`).
- `lyte-host.service` serves UDP **41151** from `versions/8d5e83fcc831`
  (#256's host; it logs `direct: capturing /dev/dri/card1`). The #253 host
  is kept: `cd ~/src/lyte-host && ./Scripts/deploy-host.sh --restart
  ~/.local/share/lyte/versions/bb4ce518dd2f`.
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: `~/.config/lyte-host/`, `~/lyte-revamp-backup/`, `~/lyte-migration-*`.
- **This Mac is paired**; its one Lyte is Homebrew's `/Applications/Lyte.app`
  (0.7.0, Sparkle-updated), streaming from pup with keyboard and mouse.

## Next

1. Next: rate recovery on a quiet screen (TODO, Host), then the
   daily-driver browser client ([TODO.md](TODO.md#browser)).
2. Owner decisions in [TODO.md](TODO.md): signing the update feed, netem
   reordering, enforcing the gates, pairing enforcement before 1.0.
