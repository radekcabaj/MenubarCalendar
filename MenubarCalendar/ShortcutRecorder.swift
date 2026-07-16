import AppKit
import SwiftUI

/// Click-to-record control for the global meeting shortcut. Captures the next
/// key-down (with at least one of ⌃/⌥/⌘) via a local event monitor and stores
/// it in `AppSettings`. Esc cancels.
struct ShortcutRecorder: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewModel: CalendarViewModel

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { cancel() } else { start() }
        } label: {
            Text(recording ? "Naciśnij skrót… (Esc)" : settings.hotKeyDisplayString)
                .frame(minWidth: 130)
                .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .onDisappear { cancel() }
    }

    private func start() {
        recording = true
        // Pause the active hot key so it doesn't fire while recording the combo.
        viewModel.pauseHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil // consume
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc
            cancel()
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags = [.command, .option, .control]
        guard !mods.isDisjoint(with: required) else {
            // A modifier is required — ignore bare keys and keep recording.
            NSSound.beep()
            return
        }
        let character = (event.charactersIgnoringModifiers ?? "").uppercased()
        settings.setHotKey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue, character: character)
        stop()
        viewModel.updateHotKey()
    }

    private func cancel() {
        stop()
        viewModel.updateHotKey()
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }
}
