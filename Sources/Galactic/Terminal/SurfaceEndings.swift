import Combine

/// A host-supplied signal that whatever a surface was showing has ended.
///
/// The process behind a terminal surface stopping is not something the surface
/// can see: what counts as "ended" is the application's own idea of a session
/// or an agent, it survives the surface being torn down and rebuilt, and the two
/// applications hold it as different things — a published flag on a durable
/// session model in one, a state enum on a controller in the other.
///
/// What shared code needs from either is the moment, so it can close anything
/// standing open over a surface that no longer has anything behind it.
///
/// ### What a host must guarantee
///
/// - **Delivered on the main thread, synchronously.** Do not add a hop. The
///   value that reports this is itself set on main, and a surface reacting to it
///   is usually being dismantled by its own application in the same turn — a
///   queued reaction arrives after the views it needed are gone, which for a
///   subscriber closing something down means the close silently does not
///   happen, and anything it was going to record with it is lost.
/// - **Once per ending.** A flag that republishes the same value must be
///   deduplicated before it is handed over, since a subscriber cannot tell a
///   repeat from a second ending.
///
/// A surface that nothing needs to hear about supplies `.never` rather than
/// nothing, so the wiring is present either way.
public typealias SurfaceEndings = AnyPublisher<Void, Never>

public extension AnyPublisher where Output == Void, Failure == Never {

    /// For a surface whose ending nobody needs to be told about.
    ///
    /// Deliberately does not complete: completion is a fact about the stream,
    /// and a subscriber that treated it as the event would act on the one thing
    /// this value exists to say will never happen.
    static var never: AnyPublisher<Void, Never> {
        Empty(completeImmediately: false).eraseToAnyPublisher()
    }
}
