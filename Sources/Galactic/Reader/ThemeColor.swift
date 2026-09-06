import Foundation

/// A colour read out of a stylesheet, for deriving the few a stylesheet does
/// not declare.
///
/// Deliberately small: hex and `rgb()` in, hex out. A theme that paints with a
/// gradient or an image has no single colour here, and is declined earlier
/// rather than approximated.
struct ThemeColor: Equatable {
    var red: Int
    var green: Int
    var blue: Int

    static let white = ThemeColor(red: 255, green: 255, blue: 255)
    static let black = ThemeColor(red: 0, green: 0, blue: 0)

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("#") {
            let digits = value.dropFirst().prefix {
                $0.isHexDigit
            }
            let expanded: String
            switch digits.count {
            // `#abc` is every digit doubled, not padded.
            case 3: expanded = digits.map { "\($0)\($0)" }.joined()
            case 6, 8: expanded = String(digits.prefix(6))
            default: return nil
            }
            guard let packed = Int(expanded, radix: 16) else { return nil }
            self.init(
                red: (packed >> 16) & 0xFF,
                green: (packed >> 8) & 0xFF,
                blue: packed & 0xFF
            )
            return
        }

        guard
            let match = value.firstMatch(
                of: #/rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/#
            ),
            let red = Int(match.1),
            let green = Int(match.2),
            let blue = Int(match.3)
        else { return nil }
        self.init(red: red, green: green, blue: blue)
    }

    var hex: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// Perceptual, 0...1. Green dominates apparent brightness, which is why a
    /// flat channel average misjudges blues and greens against each other.
    var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue))
            / 255
    }

    /// A step of `amount` of the way toward another colour.
    func mixed(toward other: ThemeColor, _ amount: Double) -> ThemeColor {
        func between(_ from: Int, _ to: Int) -> Int {
            Self.clamped(
                Int((Double(from) + (Double(to) - Double(from)) * amount)
                    .rounded())
            )
        }
        return ThemeColor(
            red: between(red, other.red),
            green: between(green, other.green),
            blue: between(blue, other.blue)
        )
    }

    /// Every channel moved by the same amount, clamped.
    func shifted(by amount: Int) -> ThemeColor {
        ThemeColor(
            red: Self.clamped(red + amount),
            green: Self.clamped(green + amount),
            blue: Self.clamped(blue + amount)
        )
    }

    private static func clamped(_ channel: Int) -> Int {
        min(255, max(0, channel))
    }
}
