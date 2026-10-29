import Foundation

@testable import Galactic

/// A host that answers on command, so the consumer's state machine can be
/// exercised with no terminal, no agent, and no timing.
///
/// Deliveries can settle immediately (`autoReport`) or be held open, because
/// the two shapes test different things: held-open is how overlap is caught,
/// and immediate is how the drain loop is driven to completion.
@MainActor
final class StubAgentInboxHost: AgentInboxHost {

    var canSendNow = true

    var sendBlockReason: String?

    /// Every unit handed over, in order, including repeats.
    private(set) var delivered: [AgentInboxUnit] = []

    /// Deliveries still waiting for the test to answer them.
    private(set) var open: [(Bool) -> Void] = []

    /// When set, a delivery reports this answer before `deliver` returns.
    var autoReport: Bool?

    var canReleaseBlock = false

    /// What `releaseBlock` answers, by whether it was forced.
    var releasesUnforced = false
    var releasesForced = true

    /// Every release asked for, by its `force` flag.
    private(set) var releaseRequests: [Bool] = []

    func releaseBlock(force: Bool, completion: @escaping (Bool) -> Void) {
        releaseRequests.append(force)
        let released = force ? releasesForced : releasesUnforced
        if released { canSendNow = true }
        completion(released)
    }

    func deliver(
        _ unit: AgentInboxUnit,
        accepted: @escaping (Bool) -> Void
    ) {
        delivered.append(unit)
        if let autoReport {
            accepted(autoReport)
        } else {
            open.append(accepted)
        }
    }

    /// Answer the oldest outstanding delivery.
    func report(_ accepted: Bool) {
        guard !open.isEmpty else { return }
        open.removeFirst()(accepted)
    }

    /// Answer the oldest outstanding delivery twice, as a host with a doubled
    /// callback would.
    func reportTwice(_ accepted: Bool) {
        guard !open.isEmpty else { return }
        let callback = open.removeFirst()
        callback(accepted)
        callback(accepted)
    }
}
