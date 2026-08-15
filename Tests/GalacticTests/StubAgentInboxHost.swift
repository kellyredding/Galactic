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

    /// Every unit handed over, in order, including repeats.
    private(set) var delivered: [AgentInboxUnit] = []

    /// Deliveries still waiting for the test to answer them.
    private(set) var open: [(Bool) -> Void] = []

    /// When set, a delivery reports this answer before `deliver` returns.
    var autoReport: Bool?

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
