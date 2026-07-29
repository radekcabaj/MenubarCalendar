import SwiftUI

@main
struct MenubarCalendarApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: CalendarViewModel
    @StateObject private var google: GoogleCalendarService
    @StateObject private var loginItem = LoginItemManager()

    init() {
        let settings = AppSettings()
        let google = GoogleCalendarService()
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
