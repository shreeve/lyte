# macOS Dev Code Signing

How Lyte's development binaries are code-signed so the login-Keychain
authorization for the client pairing key survives every rebuild — one
"Always Allow" click, not one per build.

## The problem

Lyte's pairing identity lives *inside* the login Keychain: the X25519 Noise
static (`ClientNoiseIdentity`, a generic-password item via `SecItemAdd`). The
first time a binary touches that item, macOS shows:

> "lyte-cli" wants to sign using key "…" in your keychain.

Clicking **Always Allow** records the approval in the key's Access Control List
(ACL) — but the ACL identifies the approved program by its **code signature**.
An unsigned binary has no stable signature, so macOS falls back to identifying
it by a hash of its bytes. Every `swift build` produces new bytes, so every
rebuild is, to the Keychain, a brand-new program the ACL has never seen — and
you get prompted again. Forever.

## The fix: a stable Apple-issued identity

Sign every build with the **same identity and designated requirement** (DR).
The signature bytes and code-directory hash still change with the program.
The stable DR is a rule like:

```
identifier "dev.shreeve.lyte-cli" and anchor apple generic and
certificate leaf[subject.CN] = "Apple Development: Example (TEAMID)"
```

The DR depends only on the bundle identifier and the signing certificate, not on
the binary's bytes. Rebuild all you want: the DR is identical, the ACL match
holds, and there is **no prompt**. Approve once, done.

`sign-dev.sh` uses the sole valid **Apple Development** certificate in the
user's Keychain search list. Besides stabilizing the Keychain ACL, Apple-issued
signing is Apple's documented requirement for reliable macOS Local Network
privacy tracking. If more than one certificate exists, the script fails closed:
set `LYTE_SIGNING_IDENTITY` to its 40-character SHA-1 identity hash. An exact
certificate name is also accepted when that name has only one matching hash.

See Apple's [TN3179: Understanding local network
privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

Contributors without an Apple Developer certificate can still use the
dedicated self-signed **Lyte Dev** fallback. It keeps Keychain authorization
stable, but macOS may not reliably preserve the app's Local Network privacy
record across rebuilds. Set `LYTE_SIGNING_IDENTITY="Lyte Dev"` to choose it
deliberately even when Apple identities exist.

Apple Development is local development signing. It does not notarize Lyte or
make the bundle suitable for Gatekeeper distribution.

## Where things live

| Item | Path | Notes |
|------|------|-------|
| Apple certificate | user Keychain search list | preferred; issued by Apple Development |
| Fallback cert + key + PKCS#12 | `~/.config/lyte-signing/` (`lyte-dev.{crt,key,p12}`) | mode `0600`; **not** in the repo (private key) |
| Signing keychain | `~/Library/Keychains/lyte-signing.keychain-db` | dedicated, password `lyte`, holds only this dev cert |
| Setup (one-time) | `Scripts/setup-dev-signing.sh` | creates cert + keychain; idempotent |
| Signer | `Scripts/sign-dev.sh` | signs a binary or `.app` |
| CLI build+sign | `Scripts/build-cli.sh` | build `Client/` into root `.build`, then sign |
| App build+sign | `Scripts/make-app.sh` | assembles `Lyte.app`, signs helper + app |
| App launch | `Scripts/launch-app.sh` | force-registers the signed artifact, then opens it |
| App icon | `Scripts/make-app-icon.sh` | regenerates `Client/AppIcon/AppIcon.icns` from its SVG masters |

`make-app.sh` builds the bundle completely in a private staging directory,
validates its property list, signs it, and then publishes it with one macOS
rename-swap. APFS supports that publication primitive; an unsupported swap,
failed build, or failed signature leaves the previously published
`.build/Lyte.app` intact. LaunchServices requires a valid numeric
`CFBundleVersion`. Every in-place publication receives a version greater than
the retained predecessor, with UTC epoch seconds and the reachable Git commit
count as floors. This prevents same-path rebuilds from pairing a new Mach-O
UUID with the preceding version. Deleting the prior bundle also deletes that
local monotonic record; this is development packaging, not a release-version
ledger. `LyteSourceRevision` separately records the short commit hash and a
trailing `+` for a dirty source tree.

The bundle's icon is `Client/AppIcon/AppIcon.icns` (`CFBundleIconFile`),
committed and copied as is. Its masters are `lyte-icon.svg` (64 px and up)
and `lyte-icon-small.svg` (16 and 32 px, without hairlines or background
streaks); after editing either, run `Scripts/make-app-icon.sh` and commit the
regenerated `.icns`. The menu-bar glyph is drawn in code
(`LyteUI/MenuBarGlyph.swift`). The app packaging test fails when the bundle's
icon is missing or differs from the committed file.

`launch-app.sh` force-registers the finished bundle before opening it. This is
important because atomic publication changes the app inode and every link
produces a new executable UUID. TN3179 says that UUID participates in macOS
Local Network privacy and must be present and unique. Registering only after
publication is Lyte's additional precaution: LaunchServices sees the exact
signed artifact that the next command opens; it is not a privacy-state reset.
The fixed `lsregister` path is a macOS implementation detail, checked at
runtime and confined to this development launcher.

The fallback identity is kept in its **own** keychain so `codesign` can use it
non-interactively without changing the login keychain's security posture.

## One-time setup

If `security find-identity -v -p codesigning` lists an Apple Development
certificate, no Lyte-specific signing setup is required. Otherwise run once:

```sh
Scripts/setup-dev-signing.sh
```

This will:

1. Create a 20-year self-signed code-signing cert (`CN=Lyte Dev`) in
   `~/.config/lyte-signing/` if absent. The PKCS#12 is exported with
   `-legacy` because macOS `security` cannot verify the MAC that OpenSSL 3
   writes by default.
2. Create the `lyte-signing` keychain, add it to the user search list, and
   import the identity trusted only for `/usr/bin/codesign`.
3. Run `security set-key-partition-list -S apple-tool:,apple:,codesign:` so
   `codesign` may use the private key without an interactive prompt.

Then build, sign, and run each distinct executable that accesses the pairing
identity against a host once. Click **Always Allow** separately for Lyte.app
and `lyte-cli`; each executable has its own designated requirement. Rebuilds
made through the scripts are silent thereafter.

Migrating an existing checkout from Lyte Dev to Apple Development changes its
DR once. Expect to approve the app and CLI's pairing-key access again, regrant
Local Network access, and possibly reapprove the registered helper under
System Settings → General → Login Items. Those prompts are security decisions
for the owner; build scripts never automate them.

## Everyday use

Build a signed CLI:

```sh
Scripts/build-cli.sh            # debug (default)
Scripts/build-cli.sh release
```

Build a signed app bundle:

```sh
Scripts/make-app.sh             # release (default)
Scripts/launch-app.sh
```

Only `Scripts/make-app.sh --diagnostics release` builds a bundle whose
signed Info.plist enables the diagnostic entry points (autoconnect, the
benchmark driver); `LYTE_APP_DIAGNOSTICS` in the environment is ignored.
`Scripts/benchmark-app.sh` builds that bundle at `.build/Lyte.app` itself —
there is only ever one physical copy — and rebuilds the plain bundle when
it exits. If that restore fails it prints a WARNING; run
`Scripts/make-app.sh release` before using the app again.

`make-app.sh` refuses to replace the bundle while any `Lyte` process is
running, including its helper. Assembly and scripted launch share one
non-waiting artifact lock, and publication checks process state again after
the build. Quit the existing app first, build it completely, and use the
launch script rather than opening a newly replaced bundle by hand. Finder and
other external launchers do not participate in that advisory lock, so this is
a disciplined development workflow rather than a system-wide exclusion.

If System Settings shows duplicated Lyte rows or an enabled row still produces
`Local network prohibited`, do not use `tccutil`: macOS Local Network privacy
does not provide a supported reset through that tool. Quit Lyte, retain only
one physical app copy, rebuild, and run `Scripts/launch-app.sh`; after changing
the **Lyte** switch in Privacy & Security → Local Network, use Search Again so
the app recreates its browser and sockets. Apple tracks the remaining
multiple-version pathology as a macOS bug; capture a sysdiagnose and file
Feedback if the registered current build is still denied.

Sign an arbitrary already-built target:

```sh
Scripts/sign-dev.sh .build/debug/lyte-cli
Scripts/sign-dev.sh .build/Lyte.app
```

A bare `swift build --package-path Client --scratch-path .build` rewrites
`.build/<configuration>/lyte-cli` as an ad-hoc-signed executable, replacing
the stable signature and so the keychain grant. Run the signing script again
before any CLI command that touches the client identity.

## How `sign-dev.sh` picks the identifier

The bundle identifier is part of the DR, so it must be stable per target:

- `*.app` → `dev.shreeve.lyte`
- anything else → `dev.shreeve.<basename>` (e.g. `dev.shreeve.lyte-cli`)

It selects the sole Apple Development identity, an exact name or hash override,
or the explicit Lyte Dev fallback. It signs using the identity **by SHA-1
hash** and verifies the identifier, team consistency, and matching Apple-anchor
or certificate-root requirement. If selection is absent or ambiguous it fails
closed; an ad-hoc Keychain client would invalidate the ACL invariant and Local
Network identity.

## Hardened runtime

`sign-dev.sh` signs every target — `Lyte.app`, `lyte-helperd` and
`lyte-cli` — with `--options runtime` and no entitlements, and fails closed
("not signed with the hardened runtime") when the signed CodeDirectory
lacks the `runtime` flag. `test-app-packaging.sh` checks the flag on the
app and the helper and rejects `get-task-allow`.

Why: the helper admits any process that satisfies the app's designated
requirement, and `lyte-cli` holds the Keychain pairing key. Without the
hardened runtime a same-user process could inject into either
(`DYLD_*` variables, task-port attach) and inherit that trust. No
exception entitlement is needed: the binaries link only system libraries
(`test-hermetic-linkage.sh`), use no JIT or unsigned executable memory,
and only play audio (no microphone or camera). Runtime flags are not part
of the designated requirement, so Keychain ACLs and the helper's
requirement are unaffected.

Debugging consequence: `DYLD_*` variables are ignored, and lldb,
Instruments and other tools cannot attach to a signed build. Debug the
unsigned SwiftPM binary, or re-sign a scratch copy ad hoc with
`codesign --force --sign - <copy>`. If a future feature loads third-party
in-process plugins it will need `com.apple.security.cs.disable-library-validation`.

## Verifying a signature

```sh
codesign -dvv .build/debug/lyte-cli        # Identifier / Authority / flags=0x10000(runtime)
codesign -d -r- .build/debug/lyte-cli      # the designated requirement (DR)
codesign --verify --strict .build/debug/lyte-cli
```

The DR must be **identical** across rebuilds. Apple signing names its leaf
certificate under `anchor apple generic`; the fallback names Lyte Dev's root
hash. If the DR changes, expect one fresh Keychain and Local Network grant.

The packaging gate also requires Mach-O UUIDs on the app and helper, as TN3179
recommends for reliable program identity.

## The privileged helper

`lyte-helperd` is a root launchd daemon, registered through `SMAppService`
from `Lyte.app/Contents/Library/LaunchDaemons`. It holds `awdl0` down while
a stream is active, because AWDL's channel hopping stalls the Wi-Fi radio
in bursts.

Security surface:

- One Mach service, `dev.shreeve.lyte.helper`, exporting three calls that
  take no arguments: `streamBegan`, `streamEnded`, `version`.
- The only privileged effect is the `IFF_UP` flag of `awdl0`, changed with
  `SIOCGIFFLAGS`/`SIOCSIFFLAGS` in process (no `ifconfig` subprocess).
- Holds are counted per XPC connection. A connection that ends, however it
  ends, releases its holds; the last release restores `awdl0`, and the
  daemon exits a few seconds after it goes idle.
- `SIGTERM` (launchd stop, `SMAppService` re-registration, shutdown)
  restores `awdl0` before the daemon exits.
- A daemon killed while holding (crash, `SIGKILL`) cannot restore. It
  leaves `/var/run/dev.shreeve.lyte.helper.awdl-held`, and its successor
  raises `awdl0` before accepting clients. The app's stream end always
  reaches the helper, so launchd starts that successor.
- A route watcher reasserts the hold only on `awdl0`'s own up edge.

### Registration

Registering the daemon tells launchd to run whatever `lyte-helperd` is in
the bundle as root, and the bundle is user-owned. So the app registers
only when it has to. At launch it leaves an enabled registration alone
when the registered helper answers `version` with the current value: the
XPC protocol version plus the code-directory hash of the helper's signed
code, which the helper reads once at startup and the app computes from the
helper embedded in its own bundle. It leaves a registration awaiting Login
Items approval alone too. It registers when there is no registration, or
when the enabled helper is silent or stale: a rebuild re-signs the helper
(changing its hash, so even a still-running old helper reads as stale), and
launchd then refuses the old launch requirement with `EX_CONFIG`.

Before any `register()`, the app validates the embedded helper on disk
(`SecStaticCodeCheckValidity`, every architecture, strict). The helper must
satisfy the app's own designated requirement with the helper's identifier.
A helper signed by anyone else is refused, and an existing registration is
left alone. Every XPC connection from the app, the version probe included,
installs the same requirement, so the app never talks to a foreign helper.
An unsigned app has no derivable requirement and never registers.

### Client authentication

`lyte-helperd` does not trust Mach-service reachability. Before its listener
activates, `LyteHelperSecurity` validates the running helper signature, reads
its designated requirement, and changes only the expected identifier from
`dev.shreeve.lyte-helperd` to `dev.shreeve.lyte`. The listener installs that
requirement with Foundation's macOS 13+ XPC signing API. XPC therefore rejects
a foreign peer before the listener delegate can export the root-only AWDL
operations.

Deriving from the helper rather than hard-coding a certificate preserves the
exact signer selected by `sign-dev.sh`: the Apple Development anchor and leaf
identity in the preferred path, or the Lyte Dev certificate root in the
explicit fallback. Startup fails closed if the running code is invalid, its
requirement has an unexpected shape (anything but one identifier clause, a
pinned signer, and no `or` alternative), or the rewritten requirement cannot
be compiled.

These checks exclude other signers, not other processes of the same user.
Both development identities sign without a prompt, so same-user code can
sign a binary that satisfies either requirement.

The packaging gate asks the signed helper for the derived requirement, proves
it is byte-for-byte the signed app's designated requirement, proves the app
satisfies it, and proves both the same-signed helper (wrong identifier) and an
Apple platform binary (wrong identity) fail it.

## Gotchas

- **`security find-identity -v` hides the fallback.** Apple selection uses
  `security find-identity -v -p codesigning`. The valid-only filter omits the
  self-signed Lyte Dev certificate because chain validation fails
  (`CSSMERR_TP_NOT_TRUSTED`), so fallback lookup uses plain `find-identity`
  against only the dedicated keychain. `codesign` signs by hash regardless of
  chain trust.
- **PKCS#12 import fails without `-legacy`.** `SecKeychainItemImport: MAC
  verification failed` — export the `.p12` with `openssl pkcs12 -export
  -legacy`.
- **Partition list is required.** Without `set-key-partition-list`, `codesign`
  itself triggers a keychain prompt to *use* the signing key — separate from
  the pairing-key prompt. Setup handles this.
- **Every signing key is dev-machine only.** The private key is never committed
  (`~/.config/lyte-signing/`). This is throwaway local-dev material, unrelated
  to any future notarized release identity.
- **Distinct from the pairing key.** Two different keys are in play: the
  *pairing* key (the client's Noise static, in the login keychain,
  authenticates to Lyte hosts) and the *signing* key (an Apple Development
  identity from the user's search list, or Lyte Dev from the dedicated
  keychain). A stable signing identity and DR keep the pairing key's ACL grant
  valid.
