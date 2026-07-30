import AppKit

/// The AppKit bridge for `Keystroke`, kept apart from the value type so the
/// matcher and its normalisation stay linkable without AppKit.
///
/// Everything here is deliberately trivial: the flag extraction it used to own
/// lives in `Modifiers.init(deviceFlags:)`, which the smoke target covers. What
/// remains is one field read and one conversion, small enough to review at a
/// glance.
extension Keystroke {
    public init(event: NSEvent) {
        assert(
            Modifiers.DeviceFlag.command
                == Int(NSEvent.ModifierFlags.command.rawValue)
                && Modifiers.DeviceFlag.option
                    == Int(NSEvent.ModifierFlags.option.rawValue)
                && Modifiers.DeviceFlag.control
                    == Int(NSEvent.ModifierFlags.control.rawValue)
                && Modifiers.DeviceFlag.shift
                    == Int(NSEvent.ModifierFlags.shift.rawValue),
            """
            NSEvent modifier bit positions no longer agree with the \
            Foundation-only copy in Keystroke.Modifiers.DeviceFlag
            """
        )
        self.init(
            keyCode: event.keyCode,
            modifiers: Modifiers(deviceFlags: Int(event.modifierFlags.rawValue))
        )
    }
}
