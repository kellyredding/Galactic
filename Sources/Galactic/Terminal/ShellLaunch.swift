import Foundation

/// What it takes to start a shell in a pane.
///
/// Every value here is an application's to decide — which shell the user has,
/// where it should open, what environment it inherits — and the applications
/// answer them differently enough that there is nothing to share in the
/// deciding: one resolves a working directory per session, the other has a
/// single place a shell can sensibly start.
///
/// What *is* shared is everything after the decision, which is why this exists
/// as a value rather than as a set of closures. A pane handed one of these can
/// start it without knowing where any of it came from.
public struct ShellLaunch {

    /// Absolute path to the shell binary.
    public let executable: String

    /// Where the shell opens.
    public let workingDirectory: String

    /// Environment entries, in `KEY=value` form.
    public let environment: [String]

    /// Arguments the shell is started with.
    ///
    /// Login and interactive by default, which is not an arbitrary pair: a
    /// pane's shell is a user sitting at a prompt, so it needs the profile a
    /// login shell reads and the behaviour an interactive one has. Both
    /// applications had spelled this out identically and neither had a reason
    /// to differ, so the default carries it and a caller that genuinely needs
    /// something else can still say so.
    public let arguments: [String]

    /// The name the process reports as, which is the shell's own filename.
    /// A shell started under a full path but reporting one still behaves as a
    /// login shell, and reads oddly in anything listing processes.
    public var executableName: String {
        (executable as NSString).lastPathComponent
    }

    public init(
        executable: String,
        workingDirectory: String,
        environment: [String],
        arguments: [String] = ["-il"]
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.arguments = arguments
    }
}
