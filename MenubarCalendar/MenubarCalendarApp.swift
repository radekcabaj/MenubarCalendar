import EventKit
import SwiftUI

@main
struct MenubarCalendarApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: CalendarViewModel
    @StateObject private var google: GoogleAccountStore
    @StateObject private var loginItem = LoginItemManager()

    init() {
        let settings: AppSettings
        let google: GoogleAccountStore
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // The unit-test host must not touch the real defaults or Keychain.
            let suite = "com.rc.MenubarCalendar.testhost"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            settings = AppSettings(defaults: defaults, isExistingInstall: false)
            google = GoogleAccountStore(vault: EphemeralTokenVault(), defaults: defaults)
        } else {
            // Someone who already granted calendar access was using the macOS
            // Calendar source; keep them on it until they switch in Settings.
            settings = AppSettings(
                isExistingInstall: EKEventStore.authorizationStatus(for: .event) == .fullAccess
            )
            google = GoogleAccountStore()
        }
        _settings = StateObject(wrappedValue: settings)
        _google = StateObject(wrappedValue: google)
        _viewModel = StateObject(wrappedValue: CalendarViewModel(settings: settings, google: google))
    }

    var body: some Scene {
        MenuBarExtra {
            EventListView()
                .environmentObject(viewModel)
                .environmentObject(settings)
                .environmentObject(google)
                .environmentObject(loginItem)
        } label: {
            Text(viewModel.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
