import SwiftUI

/// Root of the `.window`-style menu-bar pop-over (PRD §3.2). Shows the
/// day-grouped upcoming-events list, the settings screen, or the inline event
/// editor. Secondary screens are shown by swapping the pop-over content (the
/// same pattern as Settings) rather than sheets/alerts, which are unreliable
/// inside a `MenuBarExtra` window because it dismisses when it loses focus.
struct EventListView: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    @EnvironmentObject private var google: GoogleCalendarService
    @State private var showingSettings = false
    /// The event being edited, plus its starting values; non-nil swaps the
    /// pop-over to the editor.
    @State private var editing: EditingSession?
    /// The row awaiting a decline confirmation; non-nil shows the overlay.
    @State private var pendingDecline: EventRow?

    /// The list scrolls once it would grow past this; below it, the pop-over
    /// shrinks to (approximately) fit its content.
    private let maxListHeight: CGFloat = 440

    /// A row plus a snapshot of its editable fields, captured when the user
    /// taps Edit so the editor has stable initial values.
    struct EditingSession {
        let row: EventRow
        let draft: EventEditDraft
    }

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(onBack: { showingSettings = false })
            } else if let session = editing {
                EventEditScreen(
                    draft: session.draft,
                    onCancel: { editing = nil },
                    onSave: { updated in
                        viewModel.saveEdit(updated, rowID: session.row.id)
                        editing = nil
                    }
                )
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
        .overlay {
            if let row = pendingDecline {
                declineConfirmation(row)
            }
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
        List {
            ForEach(viewModel.sections) { section in
                Section {
                    if section.rows.isEmpty {
                        Text(section.emptyMessage ?? "No events this day")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowInsets(rowInsets)
                    } else {
                        ForEach(section.rows) { row in
                            EventRowView(row: row)
                                .listRowSeparator(.hidden)
                                .listRowInsets(rowInsets)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if row.isEditable {
                                        Button {
                                            pendingDecline = row
                                        } label: {
                                            Label("Decline", systemImage: "calendar.badge.minus")
                                        }
                                        .tint(.red)
                                        Button {
                                            beginEditing(row)
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                                }
                                .contextMenu {
                                    if row.isEditable {
                                        Button("Edit…") { beginEditing(row) }
                                        Button("Decline…", role: .destructive) {
                                            pendingDecline = row
                                        }
                                    }
                                }
                        }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .frame(height: min(max(estimatedListHeight, 44), maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
    }

    private func sectionHeader(_ section: DaySection) -> some View {
        HStack(spacing: 4) {
            Text("\(section.title),")
                .fontWeight(.semibold)
            Text(section.dateLabel)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .textCase(nil)
        .padding(.vertical, 2)
    }

    /// Approximate height of the `List` so the pop-over sizes to its content
    /// until it hits `maxListHeight`. `List` has no intrinsic size inside a
    /// `MenuBarExtra` window, so unlike the old `ScrollView` we estimate rather
    /// than measure (a few points of slack is fine).
    private var estimatedListHeight: CGFloat {
        let headerH: CGFloat = 30
        let rowH: CGFloat = 32
        let emptyH: CGFloat = 30
        let sectionGap: CGFloat = 12
        var total: CGFloat = 12
        for section in viewModel.sections {
            total += headerH
            total += section.rows.isEmpty ? emptyH : CGFloat(section.rows.count) * rowH
            total += sectionGap
        }
        return total
    }

    private func beginEditing(_ row: EventRow) {
        guard let draft = viewModel.editDraft(rowID: row.id) else {
            NSSound.beep()
            return
        }
        editing = EditingSession(row: row, draft: draft)
    }

    /// Inline "are you sure?" card for the destructive Decline action, drawn as
    /// an overlay so it stays inside the pop-over window (an `alert` would risk
    /// dismissing the whole pop-over).
    private func declineConfirmation(_ row: EventRow) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { pendingDecline = nil }
            VStack(spacing: 12) {
                Text("Decline this event?")
                    .font(.headline)
                Text(declineMessage(for: row))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Cancel") { pendingDecline = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Decline & Remove", role: .destructive) {
                        viewModel.declineEvent(rowID: row.id)
                        pendingDecline = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            .shadow(radius: 18)
        }
    }

    private func declineMessage(for row: EventRow) -> String {
        if google.isConnected {
            return "“\(row.title)” — you'll be marked as declined and the organizer will be notified. It will be removed from your list."
        }
        return "“\(row.title)” will be removed from your list. Connect a Google account in Settings if you want the organizer to be notified you declined."
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
        .contentShape(Rectangle())
    }

    private var time: Text {
        if row.isAllDay {
            return Text("All day").foregroundStyle(.secondary)
        }
        return Text(row.startTime).foregroundStyle(.primary)
            + Text(" – \(row.endTime)").foregroundStyle(.secondary)
    }
}

/// Inline event editor shown in place of the list (same pattern as Settings).
/// Edits are saved through EventKit by the caller; on synced accounts guests
/// are notified as part of the account's normal sync.
struct EventEditScreen: View {
    @State var draft: EventEditDraft
    let onCancel: () -> Void
    let onSave: (EventEditDraft) -> Void

    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.endDate >= draft.startDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Title") {
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("All-day", isOn: $draft.isAllDay)
                    field("Starts") {
                        DatePicker(
                            "", selection: $draft.startDate,
                            displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                    }
                    field("Ends") {
                        DatePicker(
                            "", selection: $draft.endDate,
                            displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        if draft.endDate < draft.startDate {
                            Text("End must be after start.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    field("Location") {
                        TextField("Location", text: $draft.location)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Notes") {
                        TextEditor(text: $draft.notes)
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    if draft.hasAttendees {
                        Label(
                            "Guests will be notified of these changes when they sync.",
                            systemImage: "person.2"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 380)
        }
    }

    private var header: some View {
        ZStack {
            Text("Edit event")
                .font(.headline)
                .fontWeight(.medium)
            HStack {
                Button {
                    onCancel()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
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
