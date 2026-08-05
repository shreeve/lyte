# macOS Dev Code Signing

How Lyte's development binaries are code-signed so the login-Keychain
authorization for the client pairing key survives every rebuild — one
"Always Allow" click, not one per build.

## The problem

Lyte's pairing identity lives *inside* the login Keychain — today the X25519
Noise static (`ClientNoiseIdentity`, a generic-password item via `SecItemAdd`);
originally the GameStream era's RSA-2048 mutual-TLS key, where this lesson was
learned. The first time a binary touches that item, macOS shows:

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

`make-app.sh` builds the bundle completely in a private staging directory,
validates its property list, signs it, and then publishes it with one macOS
rename-swap. APFS supports that publication primitive; an unsupported swap,
failed build, or failed signature leaves the previously published
`.build/Lyte.app` intact. LaunchServices requires a valid numeric
`CFBundleVersion`. Every assembly receives a monotonically fresh version whose
floor is the reachable Git commit count; rebuilding the same source can never
publish a new Mach-O UUID under the previous version. `LyteSourceRevision`
separately records the short commit hash and a trailing `+` for a dirty source
tree.

`launch-app.sh` force-registers the finished bundle before opening it. This is
important because atomic publication changes the app inode and every link
produces a new executable UUID. TN3179 says that UUID participates in macOS
Local Network privacy and must be present and unique. Registering only after
publication is Lyte's additional precaution: LaunchServices sees the exact
signed artifact that the next command opens; it is not a privacy-state reset.

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

`make-app.sh` refuses to replace the bundle while any `Lyte` process is
running. Quit the existing app first, build it completely, and use the launch
script rather than opening a newly replaced bundle by hand.

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

Prefer these over `swift build --package-path Client --scratch-path "$PWD/.build"`
whenever the binary will talk to a host, so the signature (and thus the
keychain grant) stays intact.

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

## Verifying a signature

```sh
codesign -dvv .build/debug/lyte-cli        # Identifier / Authority
codesign -d -r- .build/debug/lyte-cli      # the designated requirement (DR)
codesign --verify --strict .build/debug/lyte-cli
```

The DR must be **identical** across rebuilds. Apple signing names its leaf
certificate under `anchor apple generic`; the fallback names Lyte Dev's root
hash. If the DR changes, expect one fresh Keychain and Local Network grant.

The packaging gate also requires Mach-O UUIDs on the app and helper, as TN3179
recommends for reliable program identity.

## Gotchas (learned the hard way)

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
- **A later bare `swift build --package-path Client --scratch-path .build`
  overwrites the CLI artifact.** SwiftPM emits an
  ad-hoc-signed executable at `.build/<configuration>/lyte-cli`, replacing the
  stable signature installed by `Scripts/build-cli.sh`. Run the signing script
  again immediately before any CLI command that touches the client identity.
