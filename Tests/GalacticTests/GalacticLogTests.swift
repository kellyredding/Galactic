import XCTest
@testable import Galactic

final class GalacticLogTests: XCTestCase {

    /// The sink is package-global state, so every test restores it rather than
    /// leaving whichever ran last in force.
    override func tearDown() {
        GalacticLog.sink = GalacticLog.Sink()
        super.tearDown()
    }

    func testInstalledSinkReceivesEachChannel() {
        var submitted: [String] = []
        var debugged: [String] = []
        GalacticLog.sink = GalacticLog.Sink(
            submit: { submitted.append($0) },
            debug: { debugged.append($0) }
        )

        GalacticLog.submit("wrote text")
        GalacticLog.debug("resized")

        XCTAssertEqual(submitted, ["wrote text"])
        XCTAssertEqual(debugged, ["resized"])
    }

    /// A host that wants only the submission trail should not be forced to take
    /// the rest — that is the whole reason these are two channels and not one
    /// level.
    func testChannelsAreIndependent() {
        var submitted: [String] = []
        GalacticLog.sink = GalacticLog.Sink(submit: { submitted.append($0) })

        GalacticLog.submit("kept")
        GalacticLog.debug("dropped")

        XCTAssertEqual(submitted, ["kept"])
    }

    /// The default has to discard rather than print. A package that logs to
    /// stdout by default pollutes every consumer that never configured it.
    func testDefaultSinkDiscardsWithoutCrashing() {
        GalacticLog.sink = GalacticLog.Sink()
        GalacticLog.submit("nobody is listening")
        GalacticLog.debug("nor to this")
    }
}
