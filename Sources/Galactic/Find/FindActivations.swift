import Combine

/// A host-supplied signal that the user asked to find within a surface.
///
/// Terminal hosts do not own the ⌘F gesture — a menu does, and how a menu
/// reaches the surface that should answer is an application's own business.
/// One application increments a counter its session manager publishes; another
/// posts a notification, because its menu has no handle on whichever host is
/// live. Both are transport, and neither name can travel with shared code.
///
/// What shared code needs is narrower than either: something that fires once
/// when the user asks. Named here so the contract has one home rather than a
/// restatement per application.
///
/// ### What a host may assume
///
/// - **One emission per request.** A publisher that replays its current value
///   to new subscribers must drop that first element before handing it over,
///   or every host that mounts will believe ⌘F was just pressed.
/// - **Nothing carried.** Which surface answers is decided by the surfaces,
///   from focus memory and from whether they are what the user is looking at.
///   A signal that named its intended recipient would be making a decision the
///   sender is not in a position to make.
///
/// Stated because both are invisible when wrong: a replay opens a find bar
/// nobody asked for, at launch, on a surface nobody has looked at yet.
public typealias FindActivations = AnyPublisher<Void, Never>
