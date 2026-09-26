# Releasing and updates

`Lyte.app` is installed with Homebrew or `Scripts/install.sh` and then
updates itself through [Sparkle](https://sparkle-project.org). GitHub
Releases on `shreeve/lyte` is the only host: no server and no CI step. The
Linux host is not part of this; it deploys with
`Host/Scripts/deploy-host.sh` ([OPERATIONS.md](OPERATIONS.md)).

## How it fits together

| Piece | Where | Does |
| --- | --- | --- |
| Install | `shreeve/homebrew-tap` → `Casks/lyte.rb` | `brew install --cask shreeve/tap/lyte` downloads the release's `Lyte-X.Y.Z.zip` into `/Applications`. `auto_updates true` leaves updating to Sparkle; `livecheck` reads the same feed. |
| One-liner | `Scripts/install.sh` | `curl -fsSL https://raw.githubusercontent.com/shreeve/lyte/main/Scripts/install.sh \| bash` downloads the latest release's `Lyte.zip` and installs it into `/Applications`, or `~/Applications` when that is not writable (`LYTE_DEST` names another folder). It refuses an app not signed by a Developer ID of team `SD6N7Z8P9P` or not accepted by Gatekeeper as notarized, refuses while Lyte or `lyte-helperd` runs, and replaces an installed copy by rename, so a failure leaves it standing. `Scripts/Tests/test-install.sh` drives it in the macOS gate with local archives and fake `codesign`, `spctl` and `pgrep`. |
| Updater | `Client/Sources/Lyte/AppUpdater.swift` | Starts Sparkle only in a bundle whose Info.plist has `SUFeedURL` and `SUPublicEDKey` and is not a diagnostic build; adds **Lyte → Check for Updates…**. Sparkle owns the rest: the first-run "check automatically?" prompt, the update window, install on quit, relaunch. |
| Bundle | `Scripts/make-app.sh` | Embeds `Sparkle.framework`, thinned to arm64 and without its XPC services (Lyte is not sandboxed), and signs it with the app's identity. Only `LYTE_RELEASE_VERSION=X.Y.Z` adds the feed URL and the public key, so a development build never checks. |
| Signing | `Scripts/sign-dev.sh` | Development: the Apple Development identity, else the self-signed Lyte Dev, whose app alone carries `disable-library-validation` so it can load Sparkle ([MACOS-SIGNING.md](MACOS-SIGNING.md#hardened-runtime)). Releases: `LYTE_SIGNING_IDENTITY="Developer ID Application: …"`, with a secure timestamp and a team-anchored requirement. |
| Release | `Scripts/release.sh` | Builds with the Developer ID, notarizes and staples, zips (`Lyte-X.Y.Z.zip`, copied as `Lyte.zip`), writes `appcast.xml` with the archive's EdDSA signature, and publishes the tagged GitHub release. The feed itself is not signed yet ([TODO.md](../TODO.md)). |
| Feed | `appcast.xml` on the latest release | `SUFeedURL` is `https://github.com/shreeve/lyte/releases/latest/download/appcast.xml`. |
| Key | `Client/Updates/sparkle-public-key.txt` | The public half of the update-signing key; the private half is in the login keychain under the account `lyte`. |

Two signatures, two jobs:

- **Gatekeeper** checks a downloaded app on first launch. Homebrew marks its
  downloads as quarantined, so the app must be signed with a Developer ID
  and notarized; the release staples Apple's ticket into the bundle.
  `curl` does not quarantine, so `install.sh` runs the same assessment
  (`spctl --assess`) itself before it installs anything.
- **Sparkle** accepts an update when its code signature is valid and the
  archive's EdDSA signature (the enclosure's `sparkle:edSignature`)
  matches the installed copy's `SUPublicEDKey`.

A Developer ID signature is also what keeps the app's identity stable from
one release to the next: its designated requirement names the team, not a
per-build hash, so the Local Network permission and the helper's approval
carry across updates, and `HelperRegistration` re-registers the embedded
helper when an update replaced it.

Versions: `CFBundleShortVersionString` is the release's `X.Y.Z`, and a
development build's is the newest `vX.Y.Z` tag it descends from;
`CFBundleVersion` stays `make-app.sh`'s increasing build number, which is
what Sparkle orders updates by.

## One-time setup

**The Developer ID and notarization** are shared with Transfer: the
Developer ID Application certificate of team `SD6N7Z8P9P` in the login
keychain, and the notarytool keychain profile `notary-tool`. Setup and
recovery are in Transfer's `docs/RELEASING.md`. Check:

```bash
security find-identity -v -p codesigning   # lists "Developer ID Application: Steve Shreeve (SD6N7Z8P9P)"
xcrun notarytool history --keychain-profile notary-tool
```

**The update key** is Lyte's own, under the keychain account `lyte` (Transfer
uses the default account; never mix them). Sparkle's tools are in
`.build/artifacts/sparkle/Sparkle/bin` after any `Scripts/make-app.sh`.

```bash
bin=.build/artifacts/sparkle/Sparkle/bin
$bin/generate_keys --account lyte                                   # creates the key, prints the public half
$bin/generate_keys --account lyte -p > Client/Updates/sparkle-public-key.txt
$bin/generate_keys --account lyte -x /tmp/lyte-sparkle-key           # export a backup
```

Commit `Client/Updates/sparkle-public-key.txt`. Put the exported private key
in a password manager and delete the file. Losing it strands every installed
copy on its version, since a copy trusts only the key it shipped with;
anyone who has it can sign an update every copy accepts.

## Cutting a release

Add the version's section to `CHANGELOG.md` under `## X.Y.Z — <date>` and
commit it: it becomes the GitHub release notes and the text in Sparkle's
update window. Then, from a clean `main` in step with `origin/main`:

```bash
Scripts/release.sh X.Y.Z --notes     # the notes it would publish
Scripts/release.sh X.Y.Z --dry-run   # build, notarize and sign under .build/release-X.Y.Z; publish nothing
Scripts/release.sh X.Y.Z
```

The script refuses a real release unless the Developer ID, the notary
profile and the `lyte` key (matching the committed public key) are present,
`gh` is signed in, no tag or release `vX.Y.Z` exists, the version is higher
than the latest `v*` tag, and `CHANGELOG.md` has its section.
`LYTE_RELEASE_IDENTITY` names another Developer ID and `NOTARY_PROFILE`
another notarytool profile. It then:

1. builds `.build/release-X.Y.Z/Lyte.app` with `make-app.sh`
   (`LYTE_RELEASE_VERSION`, the Developer ID);
2. notarizes (a few minutes), staples, and checks that Gatekeeper sees a
   notarized Developer ID app;
3. zips it as `feed/Lyte-X.Y.Z.zip` beside its notes, and copies it to
   `Lyte.zip`, the one name `install.sh` fetches from
   `releases/latest/download/`;
4. writes `appcast.xml` with Sparkle's `generate_appcast --account lyte`,
   and stops if an enclosure came out without its EdDSA signature or the
   feed without notes;
5. creates the release as a draft with both zips and the feed, pushes an
   annotated tag `vX.Y.Z`, and publishes the draft as the latest release.

A failure before the tag is pushed deletes the draft and the local tag. If
only publishing the pushed draft fails, the script prints the `gh release
edit … --draft=false --latest --verify-tag` that finishes it.

Then update the cask (`version` and `sha256` of `Lyte-X.Y.Z.zip`) in
`shreeve/homebrew-tap` and land it as a pull request. Installed copies need
nothing: they find the release on their next daily check.

## The cask

`Casks/lyte.rb` in `shreeve/homebrew-tap` (no Homebrew cask is named
`lyte`). Each release changes only `version` and `sha256`. `livecheck`
takes the feed's display version, since the feed also carries the build
number Sparkle orders by (`brew audit` fails otherwise). The app is
arm64-only and needs macOS 15. Test it the way that repository's other casks
are tested (`brew style`, `brew audit --cask --online`, `brew livecheck`,
an install into a scratch `--appdir`) before its pull request lands.

```ruby
cask "lyte" do
  version "0.6.0"
  sha256 "…"

  url "https://github.com/shreeve/lyte/releases/download/v#{version}/Lyte-#{version}.zip"
  name "Lyte"
  desc "Low-latency remote desktop for a Linux host"
  homepage "https://github.com/shreeve/lyte"

  livecheck do
    url "https://github.com/shreeve/lyte/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Lyte.app"

  zap trash: [
    "~/Library/Application Support/Lyte",
    "~/Library/Caches/dev.shreeve.lyte",
    "~/Library/HTTPStorages/dev.shreeve.lyte",
    "~/Library/Preferences/dev.shreeve.lyte.plist",
  ]
end
```

## Verifying a release

```bash
gh release view vX.Y.Z --repo shreeve/lyte
curl -fsSL https://github.com/shreeve/lyte/releases/latest/download/appcast.xml | grep -E 'sparkle:(shortVersionString|version)'
curl -fsSLI https://github.com/shreeve/lyte/releases/latest/download/Lyte.zip | grep -i '^content-length'
```

A release made before `release.sh` published `Lyte.zip` has none, and the
one-liner fails with a 404 until the next release.

## Testing an update before shipping it

1. Dry-run an older version and a newer one: `Scripts/release.sh <old>
   --dry-run`, then `<new>`. Each is signed and notarized.
2. Copy the older `.build/release-<old>/Lyte.app` to a scratch folder and
   quit every other Lyte (one physical copy per bundle identity; see
   [MACOS-SIGNING.md](MACOS-SIGNING.md)).
3. Serve the newer `feed/` folder, whose `appcast.xml` names the release
   URL, after regenerating it for a local URL:
   `.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account lyte
   --download-url-prefix http://127.0.0.1:8765/ .build/release-<new>/feed`,
   then `python3 -m http.server 8765 --bind 127.0.0.1` in that folder.
4. `defaults write dev.shreeve.lyte SUFeedURL http://127.0.0.1:8765/appcast.xml`,
   open the older copy, and choose **Check for Updates…**.
5. Clean up: `defaults delete dev.shreeve.lyte SUFeedURL`, stop the server,
   delete the scratch copy.

## If something goes wrong

- **An enclosure is unsigned.** The keychain's `lyte` key does not match
  `Client/Updates/sparkle-public-key.txt`; compare
  `generate_keys --account lyte -p` with the file.
- **Notarization is refused.** The script prints Apple's log, which names
  each file: usually a piece without the hardened runtime or a secure
  timestamp, or a new executable `make-app.sh` does not sign.
- **Installed copies do not see the release.** It must be the repository's
  latest release, and its `CFBundleVersion` higher than theirs.
- **A bad release is out.** Publish a fixed, higher version; Sparkle only
  moves forward.
