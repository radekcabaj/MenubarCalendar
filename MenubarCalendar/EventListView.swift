import SwiftUI

/// Root of the `.window`-style menu-bar pop-over (PRD §3.2). Shows either the
/// day-grouped upcoming-events list or the settings screen.
struct EventListView: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    @State private var showingSettings = false
    @State private var listHeight: CGFloat = 0

    /// The list scrolls once it would grow past this; below it, the pop-over
    /// shrinks to fit its content.
    private let maxListHeight: CGFloat = 440

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
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.accessDenied {
            AccessDeniedView()
                .padding(16)
        } else if viewModel.sections.isEmpty {
            Text("No upcoming events")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
        } else {
            eventList
        }
    }

    private var eventList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.sections) { section in
                    if section.id != viewModel.sections.first?.id {
                        Divider()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    DaySectionView(section: section)
                }
            }
            .padding(.vertical, 8)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(max(listHeight, 1), maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeightKey.self) { listHeight = $0 }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A day group: a `Today, Jul 16`-style header followed by its event rows.
struct DaySectionView: View {
    let section: DaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(section.rows) { row in
                EventRowView(row: row)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("\(section.title),")
                .fontWeight(.semibold)
            Text(section.dateLabel)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// One event row: a calendar-colour ring, the time range, and the title.
struct EventRowView: View {
    let row: EventRow

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(row.calendarColor, lineWidth: 1.5)
                .frame(width: 13, height: 13)
            time
                .font(.body.monospacedDigit())
                .frame(width: 96, alignment: .leading)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var time: Text {
        if row.isAllDay {
            return Text("All day").foregroundStyle(.secondary)
        }
        return Text(row.startTime).foregroundStyle(.primary)
            + Text(" – \(row.endTime)").foregroundStyle(.secondary)
    }
}

/// Shown when calendar access is denied (PRD §3.3).
struct AccessDeniedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar access denied")
                .font(.headline)
            Text("To see your upcoming events, allow calendar access in System Settings (Privacy → Calendars).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Measures the intrinsic height of the scrollable list so the pop-over can
/// size to its content until it hits `maxListHeight`.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
