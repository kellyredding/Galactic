import XCTest

@testable import Galactic

/// A test case that indexes a root, without the background machinery a real
/// application wants attached to one.
///
/// Two things made the suite's isolation rest on the main actor rather than on
/// anything the tests said. The index is a process-wide singleton, so state
/// crosses between test cases unless something drops it; and indexing a root
/// attaches a watcher and a sweep to it, both of which write to that state
/// afterwards, on their own schedule. While every writer shared the main actor
/// a test body could not be interleaved between two of its own statements, so
/// neither cost anything — and both were invisible.
///
/// They stop being invisible the moment any of that work moves off the main
/// actor, because every mutation becomes a suspension point and a suspension
/// point is where the other writers get their turn. That is not a consequence
/// of moving the work: inserting a bare `await Task.yield()` into two
/// revalidation tests, with the store still entirely on the main actor, failed
/// six runs in twenty. The isolation was already absent; the main actor was
/// hiding it.
///
/// So the knobs are restored here rather than at each call site. A leaked one
/// is not a tidiness problem — `targetAge` left at zero makes every shard in
/// every later test instantly stale, and the suite only survived it because a
/// class that happened to run in between set it back.
@MainActor
class FileIndexIsolatedTestCase: XCTestCase {

    private var restore: (() -> Void)?

    override func setUp() async throws {
        try await super.setUp()

        let watchesForChanges = FileCorpusStore.watchesForChanges
        let targetAge = FileIndexRefreshSweep.targetAge
        let tickInterval = FileIndexRefreshSweep.tickInterval
        let refusalBackoff = FileIndexRefreshSweep.refusalBackoff
        let maxConcurrentRefreshes = FileIndexRefreshSweep.maxConcurrentRefreshes
        let overlayRebuildCeiling = FileCorpusStore.overlayRebuildCeiling
        restore = {
            FileCorpusStore.watchesForChanges = watchesForChanges
            FileIndexRefreshSweep.targetAge = targetAge
            FileIndexRefreshSweep.tickInterval = tickInterval
            FileIndexRefreshSweep.refusalBackoff = refusalBackoff
            FileIndexRefreshSweep.maxConcurrentRefreshes = maxConcurrentRefreshes
            FileCorpusStore.overlayRebuildCeiling = overlayRebuildCeiling
        }

        // One test does want real events — `testFileSystemEventsUpdateTheIndexOnTheirOwn`
        // is about nothing else — and it turns this back on for itself.
        FileCorpusStore.watchesForChanges = false
    }

    override func tearDown() async throws {
        restore?()
        restore = nil
        try await super.tearDown()
    }
}
