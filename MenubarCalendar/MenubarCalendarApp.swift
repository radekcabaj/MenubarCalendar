import EventKit
import SwiftUI

@main
struct MenubarCalendarApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: CalendarViewModel
    @StateObject private var google: GoogleAccountStore
    @StateObject private var loginItem = LoginItemManager()

    init() {
        // Someone who already granted calendar access was using the macOS
        // Calendar source; keep them on it until they switch in Settings.
        let settings = AppSettings(
            isExistingInstall: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        )
        let google = GoogleAccountStore()
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
