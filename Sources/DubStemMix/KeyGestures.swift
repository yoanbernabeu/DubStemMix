import AppKit

/// Momentary gestures on the keyboard (PRD § 11.6): key down starts, key up ends. Plain keys only, never
/// while typing in a text field, never with a modifier (⌘R stays "record").
@MainActor
final class KeyGestures {
    /// The monitor lives as long as the app: the model that owns it is never released.
    private var monitor: Any?

    init(onKey: @escaping @MainActor (_ key: String, _ down: Bool) -> Bool) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1
            else { return event }
            if event.type == .keyDown, event.isARepeat { return nil } // holding a key must not retrigger
            return MainActor.assumeIsolated { onKey(key, event.type == .keyDown) } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
