import Combine

/// A host-supplied signal that the user asked to open a scrollback surface.
///
/// The same shape, and for the same reason, as `FindActivations`: a terminal
/// host does not own the ⌘S gesture. A menu does, and how a menu reaches the
/// surface that should answer is an application's own business. Both
/// applications happen to post a notification today, but they declare its name
/// in different files and neither name can travel with shared code — and an
/// application that grew a handle on its live host would want to stop posting
/// one at all.
///
/// ### What a host may assume
///
/// - **One emission per request.** A publisher that replays its current value
///   to new subscribers must drop that first element before handing it over, or
///   every host that mounts will believe ⌘S was just pressed.
/// - **Nothing carried.** Which surface answers is decided by the surfaces,
///   from focus memory and from whether they are what the user is looking at.
///
/// Stated because both are invisible when wrong: a replay opens a scrollback
/// nobody asked for, at launch, over a surface nobody has looked at yet.
public typealias ScrollbackActivations = AnyPublisher<Void, Never>
