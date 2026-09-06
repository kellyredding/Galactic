import Foundation

/// Turns a highlight.js stylesheet into a `SourceTheme`, or says why it can't.
///
/// A highlight.js theme carries token colours and a page background, and
/// nothing about a gutter — so the two colours a code surface needs beyond
/// those are derived. The derivation only ever runs on a supplied stylesheet:
/// with none installed, `SourceTheme.stock` answers verbatim, which is why
/// these rules aim at looking right rather than at reproducing the stock
/// palette's exact values.
public enum SourceThemeStylesheet {
    /// Why a stylesheet was declined.
    ///
    /// Rejection is per appearance and falls back to stock, and it is
    /// **reported** rather than absorbed. That is the opposite of
    /// `ReaderAssets.load`, which degrades a missing resource to an empty
    /// string on purpose — right for a vendored file that can only break
    /// through a build mistake, wrong for one a person just wrote and is
    /// standing in front of.
    public enum Rejection: Error, Equatable, Sendable {
        case tooLarge(bytes: Int)
        case closesTheStyleBlock
        case reachesTheNetwork(construct: String)
        case noBackgroundDeclared

        public var reason: String {
            switch self {
            case .tooLarge(let bytes):
                return "\(bytes) bytes exceeds the \(maxBytes)-byte limit; "
                    + "the stylesheet is inlined into every source document"
            case .closesTheStyleBlock:
                return "contains `</style`, which would end the style block "
                    + "and let the rest of the file parse as HTML"
            case .reachesTheNetwork(let construct):
                return "contains `\(construct)`, which would fetch over the "
                    + "network from the reader page"
            case .noBackgroundDeclared:
                return "declares no background on its `.hljs` rule, so there "
                    + "is no page colour to draw the code on"
            }
        }
    }

    /// The stylesheet travels inline in every source document, so its size is
    /// paid per render rather than once.
    public static let maxBytes = 256 * 1024

    /// Resolve a stylesheet into a theme.
    ///
    /// Appearance is not an argument: every rule below reads the same in light
    /// and dark. That is not a convenience — it is what forced the gutter to be
    /// a luminance shift rather than a mix toward the foreground, since the
    /// gutter is darker than the page in *both* appearances and a mix would
    /// have to change direction between them.
    public static func theme(
        from css: String
    ) -> Result<SourceTheme, Rejection> {
        let bytes = css.utf8.count
        guard bytes <= maxBytes else {
            return .failure(.tooLarge(bytes: bytes))
        }
        guard css.range(of: "</style", options: .caseInsensitive) == nil else {
            return .failure(.closesTheStyleBlock)
        }
        for construct in ["@import", "url("] {
            if css.range(of: construct, options: .caseInsensitive) != nil {
                return .failure(.reachesTheNetwork(construct: construct))
            }
        }

        let bare = stripComments(css)
        guard
            let backgroundText = hljsValue(
                ["background", "background-color"], in: bare, whole: css
            ),
            let background = ThemeColor(backgroundText)
        else {
            return .failure(.noBackgroundDeclared)
        }

        // A stylesheet that sets no `.hljs` colour is unusual but legible: the
        // page's own contrast answers for it, which is what an unstyled line
        // falls back to anyway.
        let foreground =
            hljsValue(["color"], in: bare, whole: css)
            .flatMap(ThemeColor.init)
            ?? (background.luminance < 0.5 ? ThemeColor.white : .black)

        return .success(
            SourceTheme(
                highlightCSS: css,
                background: background.hex,
                foreground: foreground.hex,
                gutter: gutter(from: background).hex,
                lineNumber: background.mixed(toward: foreground, 0.46).hex,
                gutterBorder: background.mixed(toward: foreground, 0.15).hex
            )
        )
    }

    /// The gutter recedes from the page in both appearances, so it is a
    /// darkening rather than a step toward the text. Against a background
    /// already at black there is nothing darker to reach, so it lifts instead
    /// — otherwise the strip would vanish into the page.
    static func gutter(from background: ThemeColor) -> ThemeColor {
        let darker = background.shifted(by: -10)
        return darker == background ? background.shifted(by: 10) : darker
    }

    // MARK: - Reading the stylesheet

    /// The value of a property on the `.hljs` rule, following a `var()` into
    /// the stylesheet's custom properties.
    ///
    /// `whole` is the uncommented source, searched only for a `var()` target:
    /// the indirection is usually declared on `:root`, well away from the rule
    /// that references it.
    static func hljsValue(
        _ properties: [String],
        in bare: String,
        whole: String
    ) -> String? {
        for match in bare.matches(of: #/([^{}]+)\{([^{}]*)\}/#) {
            let selectors = String(match.1).split(separator: ",")
            let namesTheRule = selectors.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == ".hljs"
            }
            guard namesTheRule else { continue }
            guard
                let value = declaration(properties, in: String(match.2))
            else { continue }
            return dereference(value, in: whole)
        }
        return nil
    }

    /// Banner comments sit flush against the `.hljs` rule in almost every
    /// stylesheet upstream ships, and a rule scan reads one as part of the
    /// selector that follows it.
    static func stripComments(_ css: String) -> String {
        css.replacing(#/\/\*[\s\S]*?\*\//#, with: "")
    }

    static func declaration(
        _ properties: [String],
        in body: String
    ) -> String? {
        for declaration in body.split(separator: ";") {
            let halves = declaration.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let name = halves[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard properties.contains(name) else { continue }
            return halves[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// `var(--x)` resolved against the stylesheet's own declaration of `--x`.
    static func dereference(_ value: String, in css: String) -> String? {
        guard let reference = value.firstMatch(of: #/var\(\s*(--[\w-]+)/#)
        else { return value }
        return customProperty(String(reference.1), in: css)
    }

    static func customProperty(_ name: String, in css: String) -> String? {
        var remainder = Substring(css)
        while let found = remainder.range(of: name) {
            let after = remainder[found.upperBound...]
            let value = after.drop(while: \.isWhitespace)
            // A longer name sharing this prefix — `--bg` inside `--bg-alt` —
            // is a different property, and the colon is what tells them apart.
            if value.first == ":" {
                return value
                    .dropFirst()
                    .prefix { $0 != ";" && $0 != "}" }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            remainder = remainder[found.upperBound...]
        }
        return nil
    }
}
