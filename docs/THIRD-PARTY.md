# Third-party software

Lyte-authored code is licensed under the repository's MIT `LICENSE`.
Dependencies retain their own terms; this catalog never paraphrases or
relicenses them.

| Component | Use | License and source |
|---|---|---|
| Opus 1.6.1 | Shared client/host audio codec leaf | BSD 3-Clause; [verbatim notice](../Common/Sources/COpus/Upstream/opus-1.6.1/COPYING) and [pinned provenance](../Common/Sources/COpus/UPSTREAM.md) |
| nanors | Reed-Solomon C leaf in `LyteWire` | MIT; [verbatim notice](../Wire/Sources/CNanorsWire/LICENSE) |
| Swift Crypto | Wire cryptography implementation | Apache 2.0; exact revision is pinned in `Wire/Package.resolved` |
| Swift ASN.1 | Transitive Swift Crypto dependency | Apache 2.0; exact revision is pinned in `Wire/Package.resolved` |
| Swift Argument Parser | Client CLI parsing | Apache 2.0; exact revision is pinned in `Client/Package.resolved` |

The development app bundle carries verbatim license and notice files for
Opus, nanors, Swift Crypto, and Swift ASN.1 in `Contents/Resources/`. The
staged Linux host image carries the same applicable notices under
`usr/local/share/doc/lyte/third-party/`. Their packaging gates pin the exact
file set and verify every byte before publication. A raw local development
executable is not a distributable archive.
