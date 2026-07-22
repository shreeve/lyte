// The advertised identity (HS-10) is a HASH of the Noise static public
// key, never the key itself — the transport pillar's "host identity key
// hash". This file is lyte-host's only `import Crypto`: the same
// sanctioned provider (swift-crypto) Wire confines to its Crypto/ leaf,
// used here for one digest because LyteWire's primitives are internal.

import Crypto

enum IdentityHash {
    /// SHA-256 over the raw 32-byte X25519 static public key. Hex of this
    /// is the TXT `pkh` value CL-5 matches pinned identities against.
    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }
}
