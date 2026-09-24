import LyteWire

/// A book a control decision bumps. Shells map each onto their own
/// counters; the mapping from decision to books lives here, once.
public enum ClientControlCounter: Hashable, Sendable {
    case modeTransitionReceived
    case capabilityUpdateAnswered
    case audioRoutingStatusReceived
    case audioRoutingRequestSent
    case audioRoutingDropLoud
    case clipboardAnnounceReceived
    case clipboardIgnoredDisabled
    case clipboardDropLoud
    case cursorShapeReceived
    case unknownReliableType
    case audioTrackStateReceived
    case videoPostureStateReceived
    case malformedReliableMessage
}

extension ClientControlSessionDecision {
    /// The books this decision bumps, in no particular order.
    public var counters: [ClientControlCounter] {
        switch event {
        case .lifecycle(.modeTransition):
            return [.modeTransitionReceived]
        case .lifecycle(.sessionTeardown):
            return []
        case .malformedLifecycle, .capability(.malformed),
             .audioRouting(.malformedStatus),
             .clipboard(.malformedTextAnnounce), .cursor(.malformedShape),
             .mediaPosture(.malformedAudioState),
             .mediaPosture(.malformedVideoState):
            return [.malformedReliableMessage]
        case .capability(.updateAnswered):
            return [.capabilityUpdateAnswered]
        case .capability:
            return []
        case .audioRouting(.status(_, startup: .requested)):
            return [.audioRoutingStatusReceived, .audioRoutingRequestSent]
        case .audioRouting(.status):
            return [.audioRoutingStatusReceived]
        case .audioRouting(.unnegotiatedStatus),
             .audioRouting(.roleConfusedRequest):
            return [.audioRoutingDropLoud]
        case .clipboard(.textChanged):
            return [.clipboardAnnounceReceived]
        case .clipboard(.textIgnoredDisabled):
            return [.clipboardIgnoredDisabled]
        case .clipboard(.unnegotiatedTextAnnounce),
             .clipboard(.roleConfusedTextSet):
            return [.clipboardDropLoud]
        case .clipboard:
            return []
        case .cursor(.shape):
            return [.cursorShapeReceived]
        case .cursor(.unnegotiatedShape):
            return [.unknownReliableType]
        case .mediaPosture(.audioState):
            return [.audioTrackStateReceived]
        case .mediaPosture(.videoState):
            return [.videoPostureStateReceived]
        case .mediaPosture(.unnegotiatedAudioState),
             .mediaPosture(.unnegotiatedVideoState):
            return []
        }
    }

    /// The protocol-weather line this decision owes the operator, or nil
    /// when it speaks through a typed event or says nothing. Payload
    /// bytes never appear here.
    public var note: String? {
        switch event {
        case .lifecycle:
            return nil
        case .malformedLifecycle(.modeTransition):
            return "malformed mode transition dropped"
        case .malformedLifecycle(.sessionTeardown):
            return "malformed session teardown dropped"
        case .capability(.agreed), .capability(.failed),
             .capability(.updateAnswered):
            return nil
        case .capability(.malformed(.declaration)):
            return "malformed capability declaration dropped"
        case .capability(.malformed(.update)):
            return "malformed capability update dropped"
        case .capability(.refused(.declaration, let failure)):
            return "capability declaration refused: \(failure)"
        case .capability(.refused(.update, let failure)):
            return "capability update refused: \(failure)"
        case .audioRouting(.status(
            let hostMode, startup: .requested(let desired)
        )):
            return "session-start posture: asked host for \(desired) "
                + "(host default \(hostMode))"
        case .audioRouting(.status(_, startup: .refused(_, let error))):
            return "session-start posture ask refused: \(error)"
        case .audioRouting(.status(_, startup: .none)):
            return nil
        case .audioRouting(.malformedStatus):
            return "malformed audio-routing status dropped"
        case .audioRouting(.unnegotiatedStatus):
            return "audio-routing 0x19 without negotiated key 9 — dropped"
        case .audioRouting(.roleConfusedRequest):
            return "audio-routing 0x18 arrived AT the client "
                + "(role confusion) — dropped"
        case .clipboard(.textChanged):
            return nil
        case .clipboard(.malformedTextAnnounce):
            return "malformed clipboard announce dropped"
        case .clipboard(.unnegotiatedTextAnnounce):
            return "clipboard 0x1B without negotiated key 10 — dropped"
        case .clipboard(.textIgnoredDisabled(let byteCount)):
            return "clipboard 0x1B while sharing is off — ignored "
                + "(\(byteCount) B never applied)"
        case .clipboard(.roleConfusedTextSet):
            return "clipboard 0x1A arrived AT the client "
                + "(role confusion) — dropped"
        case .clipboard(.malformedImageCargo), .clipboard(.unnegotiatedImageCargo),
             .clipboard(.image):
            return nil   // Image words ride the bulk channel, not this seam.
        case .cursor(.shape):
            return nil
        case .cursor(.malformedShape):
            return "malformed cursor shape dropped"
        case .cursor(.unnegotiatedShape):
            return "cursor 0x24 without negotiated key 13 — dropped"
        case .mediaPosture(.audioState):
            return nil
        case .mediaPosture(.videoState(let state, changed: let changed)):
            guard changed else { return nil }
            return state.posture == .quiet
                ? "video quiet — keepalive \(state.keepaliveSeconds)s announced"
                : "video active — keepalive 1 s"
        case .mediaPosture(.malformedAudioState):
            return "malformed audio track state dropped"
        case .mediaPosture(.malformedVideoState):
            return "malformed video posture state dropped"
        case .mediaPosture(.unnegotiatedAudioState):
            return "audio track-state 0x25 without negotiated key 15 — dropped"
        case .mediaPosture(.unnegotiatedVideoState):
            return "video posture 0x26 without negotiated key 16 — dropped"
        }
    }
}
