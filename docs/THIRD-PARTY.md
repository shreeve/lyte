# Third-party software

Lyte-authored code is licensed under the repository's MIT `LICENSE`.
Dependencies keep their own terms; this catalog never paraphrases or
relicenses them.

## Shipped in Lyte binaries

| Component | Use | License and source |
|---|---|---|
| Opus 1.6.1 | Shared client/host audio codec leaf (`COpus`) | BSD 3-Clause; [verbatim notice](../Common/Sources/COpus/Upstream/opus-1.6.1/COPYING) and [pinned provenance](../Common/Sources/COpus/UPSTREAM.md) |
| nanors | Reed-Solomon C leaf in `LyteWire` (`CNanorsWire`) | MIT; [verbatim notice](../Wire/Sources/CNanorsWire/LICENSE) |
| Swift Crypto | Wire cryptography | Apache 2.0; revision pinned in `Wire/Package.resolved` |
| Swift ASN.1 | Transitive Swift Crypto dependency | Apache 2.0; revision pinned in `Wire/Package.resolved` |
| Swift Argument Parser | `lyte-cli` argument parsing | Apache 2.0; revision pinned in `Client/Package.resolved` |
| Sparkle 2.10.0 | In-app updates, embedded in `Lyte.app` as `Contents/Frameworks/Sparkle.framework` ([RELEASING.md](RELEASING.md)) | MIT (with the notices of the code it includes); pinned exactly in `Client/Package.swift` |

The app bundle carries verbatim license and notice files for Opus, nanors,
Swift Crypto, Swift ASN.1 and Sparkle in `Contents/Resources/`. The
staged Linux host image carries the applicable notices under
`doc/third-party/`, installed to `~/.local/share/lyte/doc/`. Both packaging
gates pin the exact file set and verify every byte. A raw local development
executable is not a distributable archive.

## Browser proof and development tooling

Not part of the macOS app or the Linux host image.

| Component | Use | License and source |
|---|---|---|
| JavaScriptKit | JS↔WASM bridge in the `LyteClientBrowser` WebAssembly module | MIT; version pinned in `Browser/Package.resolved` |
| swift-syntax | Build-time dependency of JavaScriptKit's macros; not linked into the module | Apache 2.0; version pinned in `Browser/Package.resolved` |
| rwebtransport | WebTransport server in the local `lyte-wt-sidecar` relay (Node) | Apache 2.0; npm, version and integrity pinned in `Browser/Harness/package-lock.json` |
| `@bjorn3/browser_wasi_shim` 0.4.1 | WASI shim for the browser page, vendored in `Browser/Page/vendor/browser_wasi_shim/` | MIT OR Apache-2.0; both licenses beside the files |
