import LyteWire

extension LyteUdpSession.Config {
    /// A session declaring one client posture — the single assembly every
    /// shell dials with (the app's first connect and roaming re-dials,
    /// wire-view):
    /// - `hostAudioRouting`: the host-speaker posture to ask for once the
    ///   host's first status arrives; nil takes the host's own default.
    /// - `shareClipboard` / `shareClipboardImages`: the core's consent
    ///   gates. Images move only while text sharing is also on; the core
    ///   enforces that, so the images gate may stand while text is off.
    /// - `chroma`: the declared tier. Declaration is the choice; changing
    ///   it means a clean reconnect.
    public init(
        hostAudioRouting: HostAudioRoutingMode?,
        shareClipboard: Bool,
        shareClipboardImages: Bool,
        chroma: ChromaTier
    ) {
        self.init()
        core.desiredHostAudioRouting = hostAudioRouting
        core.shareClipboard = shareClipboard
        core.shareClipboardImages = shareClipboardImages
        core.capabilities = core.capabilities.declaringChroma(tier: chroma)
    }
}
