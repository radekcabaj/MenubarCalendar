import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hot key via Carbon's `RegisterEventHotKey`.
///
/// Carbon hot keys work globally without the Accessibility permission (unlike
/// `NSEvent` global monitors) and need no third-party dependency. The pressed
/// event is delivered on the main run loop; we hop to the main queue before
/// invoking the action to be safe.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private let hotKeyID = EventHotKeyID(signature: 0x4D43_414C /* 'MCAL' */, id: 1)

    /// Register (replacing any existing) a hot key for `keyCode` + `modifierFlags`.
    func register(keyCode: Int, modifierFlags: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        unregister()
        self.action = action
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(from: modifierFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.action?() }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandlerRef
        )
    }

    /// Translate Cocoa modifier flags into Carbon's hot-key modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
