import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for launch-at-login (PRD §3.6).
///
/// `SMAppService.status` is the source of truth — the user may toggle the login
/// item from System Settings, so we always re-read it after any change and on
/// demand (`refresh()`).
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published var errorMessage: String?

    init() {
        refresh()
    }

    /// Re-read the real state from the system.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register / unregister the app as a login item. Failures are surfaced via
    /// `errorMessage` rather than crashing (PRD §3.6).
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = "Nie udało się zmienić autostartu: \(error.localizedDescription)"
        }
        refresh()
    }
}
