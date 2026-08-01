import AppKit
import Combine

/// The application-wide moments shared terminal code has to react to.
///
/// Unlike the other signals here this one needs no host to supply it: quitting
/// is AppKit's own event, it means the same thing in every application, and
/// observing it directly names nothing an application owns. A seam here would
/// be two hosts passing through a value neither of them decides.
public enum ApplicationLifecycle {

    /// Fires as the application is about to quit.
    ///
    /// **Nothing in a chain from here may hop queues.** The notification already
    /// arrives on main, and work queued during termination is simply dropped —
    /// the run loop does not come back around. A subscriber that adds
    /// `receive(on:)` for tidiness gets a closure that never runs, on the one
    /// path where what it was closing down is the last chance to do so.
    public static var willTerminate: AnyPublisher<Void, Never> {
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
