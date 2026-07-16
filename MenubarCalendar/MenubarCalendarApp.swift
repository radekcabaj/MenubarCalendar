import SwiftUI

@main
struct MenubarCalendarApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: CalendarViewModel
    @StateObject private var loginItem = LoginItemManager()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: CalendarViewModel(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            EventListView()
                .environmentObject(viewModel)
                .environmentObject(settings)
                .environmentObject(loginItem)
        } label: {
            Text(viewModel.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
