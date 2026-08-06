import AppKit

/// Reports key equivalents claimed by more than one menu item.
///
/// Two items sharing a key equivalent and modifier mask do not both stay
/// bound. AppKit resolves the duplicate by unbinding one, silently, with
/// nothing in the source to read and nothing at build time to catch it —
/// the losing item simply stops answering its keystroke while continuing
/// to look correct in the menu, in the source, and in a cheat sheet that
/// restates it.
///
/// Here rather than in either app because both build their menus the same
/// way and both can make the same mistake, and because a diagnostic that
/// exists in one app is a diagnostic the other learns the hard way.
///
/// A runtime audit rather than a test: the smoke targets are
/// Foundation-only by design and never see an `NSMenu`, so the only place
/// this question can be asked is a running app.
public enum MenuKeyEquivalentAudit {

    /// Walk `menu` and hand every duplicated key equivalent to `log`.
    ///
    /// Returns the number of duplicated bindings found, so a caller can
    /// assert on it if it ever wants to be stricter than a log line.
    ///
    /// Correctly-formed alternates are not reported: an alternate shares
    /// its predecessor's key equivalent and differs in modifiers, so the
    /// pair keys differently here. Disabled and hidden items *are*
    /// reported, because a duplicate steals the binding whether or not it
    /// would have acted on it.
    @discardableResult
    public static func report(
        _ menu: NSMenu,
        log: (String) -> Void
    ) -> Int {
        var claims: [String: [String]] = [:]
        collect(menu, path: "", into: &claims)

        let duplicates = claims.filter { $0.value.count > 1 }
        for (binding, owners) in duplicates.sorted(by: { $0.key < $1.key }) {
            log(
                "duplicate key equivalent \(binding) claimed by "
                    + owners.joined(separator: ", ")
                    + " — one of these is silently unbound"
            )
        }
        return duplicates.count
    }

    private static func collect(
        _ menu: NSMenu,
        path: String,
        into claims: inout [String: [String]]
    ) {
        for item in menu.items {
            let key = item.keyEquivalent
            if !key.isEmpty {
                claims[describe(key: key, mask: item.keyEquivalentModifierMask),
                       default: []]
                    .append("\(path)/\(item.title)")
            }
            if let submenu = item.submenu {
                collect(
                    submenu,
                    path: path + "/" + item.title,
                    into: &claims
                )
            }
        }
    }

    /// A stable name for one binding.
    ///
    /// Lower-cased because AppKit treats an upper-case key equivalent as
    /// the shifted form of the same key: an item with `"K"` and an item
    /// with `"k"` plus `.shift` are the same keystroke and must collide
    /// here, or the audit misses the most likely way to author one twice.
    private static func describe(
        key: String, mask: NSEvent.ModifierFlags
    ) -> String {
        var effective = mask
        if key.count == 1, key.lowercased() != key {
            effective.insert(.shift)
        }
        var parts: [String] = []
        if effective.contains(.control) { parts.append("ctrl") }
        if effective.contains(.option) { parts.append("opt") }
        if effective.contains(.shift) { parts.append("shift") }
        if effective.contains(.command) { parts.append("cmd") }
        let printable = key.lowercased()
            .unicodeScalars
            .map { $0.value < 0x20 || $0.value > 0xF700
                ? "U+\(String($0.value, radix: 16, uppercase: true))"
                : String($0) }
            .joined()
        return "[" + (parts + [printable]).joined(separator: "+") + "]"
    }
}
