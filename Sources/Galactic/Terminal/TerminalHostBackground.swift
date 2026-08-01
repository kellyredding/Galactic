import AppKit

/// The colour behind a terminal, in the strip the padding leaves exposed.
///
/// A terminal surface is mounted inset — `GalacticTerminalContainerView` carries
/// the padding, because a terminal view with an offset frame clips its own
/// leftmost column. That inset leaves a border of the *host* view showing on
/// all four sides, and the host is not the terminal, so it does not get the
/// terminal's colour for free.
///
/// Left unpainted, the strip renders as whatever sits behind it — which reads as
/// a seam between the terminal and the chrome above it, most visibly where a
/// pane divider's border line meets a background it does not match. Painting the
/// host in the terminal's own background colour is what makes the padding look
/// like part of the terminal rather than a gap around it.
///
/// A function of the theme and nothing else, so both the initial paint and every
/// repaint after a theme change are the same call. Hosts supply the theme name
/// from their own settings; which theme is configured is the app's business,
/// while what the strip should look like is not.
public enum TerminalHostBackground {

    /// Paint `view`'s layer in the background colour of the named theme.
    ///
    /// Enables layer backing rather than assuming it: the paint is meaningless
    /// without it, and a host that has not turned it on would otherwise fail
    /// silently and look exactly like a host that never called this.
    public static func apply(to view: NSView, themeNamed themeName: String) {
        let theme = TerminalColorTheme.theme(named: themeName)
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.backgroundColorValue.cgColor
    }
}
