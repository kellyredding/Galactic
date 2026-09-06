import JavaScriptCore
import XCTest
@testable import Galactic

/// The corrections in `grammar-fixes.js`, checked by running the JavaScript
/// this package actually ships.
///
/// Asserting the file is present would prove nothing: the corrections work by
/// wrapping a function the grammars call on their way in, so an ordering
/// mistake, a renamed upstream rule, or a grammar that stops arriving through
/// that path all leave a file that is present and inert. Highlighting a
/// snippet and reading the scopes back is the only check that can tell those
/// apart from a working one.
final class GrammarFixesTests: XCTestCase {
    private var context: JSContext!

    override func setUp() {
        super.setUp()
        context = JSContext()
        // The library is a UMD bundle that sniffs its environment. Neither
        // object is touched by the highlighting path, but their absence
        // changes which branch of the wrapper runs.
        context.evaluateScript("var window = {}; var document = {};")
        context.evaluateScript(ReaderAssets.highlightJS)
        context.evaluateScript(Self.scopeReader)
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    /// Flattens highlighted markup to `text[scope]` runs, so an assertion can
    /// name what it expects rather than matching HTML.
    private static let scopeReader = """
        function galaxyScopes(code, language) {
            var html = hljs.highlight(
                code, { language: language, ignoreIllegals: true }
            ).value;
            var out = [], stack = [], i = 0;
            while (i < html.length) {
                if (html[i] === '<') {
                    var end = html.indexOf('>', i);
                    var tag = html.slice(i, end + 1);
                    if (tag.indexOf('</') === 0) {
                        stack.pop();
                    } else if (tag.indexOf('<span') === 0) {
                        stack.push(
                            tag.match(/class="([^"]+)"/)[1]
                                .replace(/hljs-/g, '')
                        );
                    }
                    i = end + 1;
                    continue;
                }
                var next = html.indexOf('<', i);
                if (next === -1) { next = html.length; }
                var text = html.slice(i, next).trim();
                if (text) {
                    out.push(text + '[' + (stack.join('>') || '-') + ']');
                }
                i = next;
            }
            return out.join(' ');
        }
        """

    private func scopes(_ code: String, _ language: String) -> String {
        let escaped = code.replacingOccurrences(of: "'", with: "\\'")
        return context.evaluateScript(
            "galaxyScopes('\(escaped)', '\(language)')"
        )?.toString() ?? ""
    }

    /// The library evaluates and highlights at all — every assertion below
    /// would pass vacuously against an empty string otherwise.
    func testTheShippedJavaScriptRuns() {
        XCTAssertEqual(scopes("def settings", "ruby"),
                       "def[keyword] settings[title function_]")
    }

    func testTheCorrectionsReachBothGrammars() {
        let applied = context
            .evaluateScript("hljs.__galaxyGrammarFixes.join(',')")?
            .toString()

        XCTAssertEqual(applied, "ruby,crystal")
    }

    // MARK: - A class name ending in capitals

    /// Upstream's name pattern is an alternation whose first branch matches
    /// the shorter prefix and wins, leaving the branch written for names
    /// ending in capitals unreachable. `LdotRB` scoped as `Ldot`.
    func testARubyClassNameEndingInCapitalsIsWhole() {
        XCTAssertEqual(scopes("module LdotRB", "ruby"),
                       "module[keyword] LdotRB[title class_]")
        XCTAssertEqual(scopes("class GalaxyIO", "ruby"),
                       "class[keyword] GalaxyIO[title class_]")
    }

    /// The correction is not a reordering of those two branches: that breaks
    /// every name the first branch was right about, taking `FooBar` to `FooB`.
    func testTheNamesUpstreamAlreadyGotRightAreUnchanged() {
        for name in ["FooBar", "HTTPServer", "Config", "AssistAnt"] {
            XCTAssertEqual(scopes("module \(name)", "ruby"),
                           "module[keyword] \(name)[title class_]")
        }
    }

    /// A superclass carries its own scope, and the corrected rule has to match
    /// the inheritance form as well or it wins the race and swallows it.
    func testAnInheritedClassKeepsItsOwnScope() {
        XCTAssertEqual(
            scopes("class Foo < Bar", "ruby"),
            "class[keyword] Foo[title class_] &lt;[-] "
                + "Bar[title class_ inherited__]"
        )
    }

    // MARK: - A method defined on a receiver

    /// Neither grammar knows a definition can name a receiver, so the receiver
    /// was scoped as the method and the method itself was left plain.
    func testARubySingletonMethodNamesTheMethodNotTheReceiver() {
        XCTAssertEqual(
            scopes("def self.settings", "ruby"),
            "def[keyword] self[variable language_] .[-] "
                + "settings[title function_]"
        )
        XCTAssertEqual(
            scopes("def Foo.settings", "ruby"),
            "def[keyword] Foo[variable language_] .[-] "
                + "settings[title function_]"
        )
    }

    /// The same defect, and the same correction, in the other grammar.
    func testACrystalSingletonMethodNamesTheMethodNotTheReceiver() {
        XCTAssertEqual(
            scopes("def self.settings", "crystal"),
            "def[keyword] self[variable language_] .[-] "
                + "settings[title function_]"
        )
    }

    /// A definition with no receiver still reaches upstream's own rule.
    func testAPlainDefinitionIsLeftToUpstream() {
        XCTAssertEqual(scopes("def settings?", "ruby"),
                       "def[keyword] settings?[title function_]")
        XCTAssertEqual(scopes("def settings", "crystal"),
                       "def[function>keyword] settings[function>title]")
    }
}
