# macOS Dev Code Signing

How Lyte's development binaries are code-signed so the login-Keychain
authorization for the client pairing key survives every rebuild — one
"Always Allow" click, not one per build.

## The problem

Lyte's pairing identity is an RSA-2048 private key generated *inside* the login
Keychain (`ClientIdentity.createInKeychain()`), used to sign the mutual-TLS
handshake to a Sunshine host (`SecKeyCreateSignature`, 47984). The first time a
binary touches that key, macOS shows:

> "lyte-cli" wants to sign using key "…" in your keychain.

Clicking **Always Allow** records the approval in the key's Access Control List
(ACL) — but the ACL identifies the approved program by its **code signature**.
An unsigned binary has no stable signature, so macOS falls back to identifying
it by a hash of its bytes. Every `swift build` produces new bytes, so every
rebuild is, to the Keychain, a brand-new program the ACL has never seen — and
you get prompted again. Forever.

## The fix: a stable signing identity

Give every build the **same** code signature. macOS then records the approval
against the signature's *designated requirement* (DR) — a rule like:

```
identifier "dev.shreeve.lyte-cli" and certificate root = H"6a07…c23f"
```

The DR depends only on the bundle identifier and the signing certificate, not on
the binary's bytes. Rebuild all you want: the DR is identical, the ACL match
holds, and there is **no prompt**. Approve once, done.

We use a dedicated **self-signed** code-signing certificate ("Lyte Dev"). No
Apple Developer account is required for local development.

## Where things live

| Item | Path | Notes |
|------|------|-------|
| Cert + key + PKCS#12 | `~/.config/lyte-signing/` (`lyte-dev.{crt,key,p12}`) | mode `0600`; **not** in the repo (private key) |
| Signing keychain | `~/Library/Keychains/lyte-signing.keychain-db` | dedicated, password `lyte`, holds only this dev cert |
| Setup (one-time) | `Scripts/setup-dev-signing.sh` | creates cert + keychain; idempotent |
| Signer | `Scripts/sign-dev.sh` | signs a binary or `.app` |
| CLI build+sign | `Scripts/build-cli.sh` | `swift build --product lyte-cli` then sign |
| App build+sign | `Scripts/make-app.sh` | assembles `Lyte.app`, signs helper + app |

The identity is kept in its **own** keychain rather than the login keychain so
`codesign` can use the key non-interactively (via a known keychain password +
partition list) without changing the login keychain's security posture.

## One-time setup

On a fresh machine (or after a Keychain reset), run once:

```sh
Scripts/setup-dev-signing.sh
```

This will:

1. Create a 20-year self-signed code-signing cert (`CN=Lyte Dev`) in
   `~/.config/lyte-signing/` if absent. The PKCS#12 is exported with
   `-legacy` because macOS `security` cannot verify the MAC that OpenSSL 3
   writes by default.
2. Create the `lyte-signing` keychain, add it to the user search list, and
   import the identity with an open ACL (`-A`).
3. Run `security set-key-partition-list -S apple-tool:,apple:,codesign:` so
   `codesign` may use the private key without an interactive prompt.

Then build, sign, and run the binary against a host **once** and click
**Always Allow** on the (final) prompt for the *pairing* key. Every rebuild
after that is silent.

## Everyday use

Build a signed CLI:

```sh
Scripts/build-cli.sh            # debug (default)
Scripts/build-cli.sh release
```

Build a signed app bundle:

```sh
Scripts/make-app.sh             # release (default)
```

Sign an arbitrary already-built target:

```sh
Scripts/sign-dev.sh .build/debug/lyte-cli
Scripts/sign-dev.sh .build/Lyte.app
```

Prefer these over a bare `swift build` whenever the binary will talk to a host,
so the signature (and thus the keychain grant) stays intact.

## How `sign-dev.sh` picks the identifier

The bundle identifier is part of the DR, so it must be stable per target:

- `*.app` → `dev.shreeve.lyte`
- anything else → `dev.shreeve.<basename>` (e.g. `dev.shreeve.lyte-cli`)

It signs with `--force --timestamp=none` using the identity **by SHA-1 hash**.
If the identity is missing it signs **ad-hoc** and prints a warning, so a
checkout without the cert still builds — it just re-prompts until setup is run.

## Verifying a signature

```sh
codesign -dvv .build/debug/lyte-cli        # Identifier / Authority=Lyte Dev
codesign -d -r- .build/debug/lyte-cli      # the designated requirement (DR)
codesign --verify --strict .build/debug/lyte-cli
```

The DR's `certificate root = H"…"` hash must be **identical** across rebuilds —
that constancy is the whole point. If it changes, the signing cert changed and
you'll get one fresh prompt.

## Gotchas (learned the hard way)

- **`security find-identity -v` hides this identity.** The `-v` (valid-only)
  filter runs chain validation, which a self-signed cert fails
  (`CSSMERR_TP_NOT_TRUSTED`). Both scripts therefore use plain
  `security find-identity` (no `-v`); `codesign` signs by hash regardless of
  chain trust.
- **PKCS#12 import fails without `-legacy`.** `SecKeychainItemImport: MAC
  verification failed` — export the `.p12` with `openssl pkcs12 -export
  -legacy`.
- **Partition list is required.** Without `set-key-partition-list`, `codesign`
  itself triggers a keychain prompt to *use* the signing key — separate from
  the pairing-key prompt. Setup handles this.
- **The signing cert is dev-machine only.** The private key is never committed
  (`~/.config/lyte-signing/`). This is throwaway local-dev material, unrelated
  to any future notarized release identity.
- **Distinct from the pairing key.** Two different keys are in play: the
  *pairing* key (`Lyte Client Identity`, in the login keychain, authenticates
  to Sunshine) and the *signing* key (`Lyte Dev`, in the lyte-signing keychain,
  signs our binaries). Signing the binary stably is what keeps the pairing
  key's ACL grant valid.
