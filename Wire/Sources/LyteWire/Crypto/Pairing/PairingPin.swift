// The pairing PIN as a person types it versus the bytes CPace consumes.
// The host mints six ASCII digits and derives its generator from exactly
// those bytes, so a client must hand CPace the same six ASCII bytes. Any
// other digit form — fullwidth digits from an IME (U+FF10…U+FF19), Arabic-
// Indic, Devanagari… — is refused before it can spend one of the host's
// three guesses on a certain `confirmationFailed`. Spaces and hyphens a
// person uses to chunk the number are ignored.

public enum PairingPin {
    /// Digits in a host-minted PIN.
    public static let digitCount = 6

    /// The CPace PRS bytes for a typed PIN: its ASCII digits, when there
    /// are exactly `digitCount` of them and nothing else but spaces or
    /// hyphens; nil otherwise.
    public static func normalize(_ entered: String) -> [UInt8]? {
        var digits: [UInt8] = []
        for scalar in entered.unicodeScalars {
            switch scalar {
            case "0"..."9":
                digits.append(UInt8(scalar.value))
            case " ", "-", "\t":
                continue
            default:
                return nil
            }
        }
        return digits.count == digitCount ? digits : nil
    }

    /// True when `entered` normalizes to a PIN.
    public static func isValid(_ entered: String) -> Bool {
        normalize(entered) != nil
    }
}
