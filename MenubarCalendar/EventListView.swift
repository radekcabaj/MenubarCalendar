import SwiftUI

/// Root of the `.window`-style menu-bar pop-over (PRD §3.2). Shows either the
/// upcoming-events list or the settings screen.
struct EventListView: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    @State private var showingSettings = false

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(onBack: { showingSettings = false })
            } else {
                mainContent
            }
        }
        .frame(width: 340)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        Text("Nadchodzące")
            .font(.headline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.accessDenied {
            AccessDeniedView()
                .padding(16)
        } else if viewModel.upcomingEvents.isEmpty {
            Text("Brak nadchodzących wydarzeń")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
        } else {
            VStack(spacing: 0) {
                ForEach(viewModel.upcomingEvents) { row in
                    EventRowView(row: row)
                    if row.id != viewModel.upcomingEvents.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.reload()
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Label("Ustawienia", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Zakończ", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// One event row: colour dot, title + calendar name, and the time/all-day label.
struct EventRowView: View {
    let row: EventRow

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(row.calendarColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                Text(row.calendarTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(row.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// Shown when calendar access is denied (PRD §3.3).
struct AccessDeniedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brak dostępu do kalendarza")
                .font(.headline)
            Text("Aby zobaczyć nadchodzące wydarzenia, zezwól aplikacji na dostęp do kalendarza w Ustawieniach systemowych (Prywatność → Kalendarze).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Otwórz Ustawienia systemowe") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(.top, 2)
        }
    }
}
