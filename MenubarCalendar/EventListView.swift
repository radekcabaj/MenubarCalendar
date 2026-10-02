import SwiftUI

/// Root of the `.window`-style menu-bar pop-over (PRD §3.2). Shows the
/// day-grouped upcoming-events list, the settings screen, or the inline event
/// editor. Secondary screens are shown by swapping the pop-over content (the
/// same pattern as Settings) rather than sheets/alerts, which are unreliable
/// inside a `MenuBarExtra` window because it dismisses when it loses focus.
struct EventListView: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    @EnvironmentObject private var google: GoogleAccountStore
    @State private var showingSettings = false
    /// The event being edited, plus its starting values; non-nil swaps the
    /// pop-over to the editor.
    @State private var editing: EditingSession?
    /// The row awaiting a decline confirmation; non-nil shows the overlay.
    @State private var pendingDecline: EventRow?
    /// The row the cursor is over; drives the single blue highlight that slides
    /// between rows. When nil, the highlight rests on the current event.
    @State private var hoveredRowID: EventRow.ID?
    /// Shared namespace so the one highlight animates its move between rows
    /// instead of fading in/out per row.
    @Namespace private var highlightNamespace

    /// The list scrolls once it would grow past this; below it, the pop-over
    /// shrinks to (approximately) fit its content.
    private let maxListHeight: CGFloat = 440
    private let nav = Animation.snappy(duration: 0.32)

    /// A row plus a snapshot of its editable fields, captured when the user
    /// taps Edit so the editor has stable initial values.
    struct EditingSession {
        let row: EventRow
        let draft: EventEditDraft
    }

    var body: some View {
        ZStack {
            if showingSettings {
                SettingsView(onBack: { withAnimation(nav) { showingSettings = false } })
                    .transition(.push(from: .trailing))
            } else if let session = editing {
                EventEditScreen(
                    draft: session.draft,
                    onCancel: { withAnimation(nav) { editing = nil } },
                    onSave: { updated in
                        viewModel.saveEdit(updated, rowID: session.row.id)
                        withAnimation(nav) { editing = nil }
                    }
                )
                .transition(.push(from: .trailing))
            } else {
                mainContent
                    .transition(.push(from: .leading))
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
            emptyState
        } else {
            eventList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No upcoming events")
                .foregroundStyle(.secondary)
            Text("You're all caught up.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var eventList: some View {
        List {
            ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) { index, section in
                // A thin line groups each day with its events (not before the first).
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 1)
                        .padding(.vertical, 10)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                dayHeader(section, isFirst: index == 0)

                if section.rows.isEmpty {
                    // Mirror an event row's wrapper exactly so the gap under the
                    // day header matches the gap in days that have events.
                    HStack(spacing: 0) {
                        Text(section.emptyMessage ?? "No events this day")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                } else {
                    ForEach(section.rows) { row in
                        EventRowView(
                            row: row,
                            isHighlighted: highlightedRowID == row.id,
                            namespace: highlightNamespace,
                            onJoin: { viewModel.openMeeting(rowID: row.id) },
                            onHoverChange: { hovering in
                                withAnimation(.snappy(duration: 0.22)) {
                                    if hovering {
                                        hoveredRowID = row.id
                                    } else if hoveredRowID == row.id {
                                        hoveredRowID = nil
                                    }
                                }
                            }
                        )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if row.canDecline {
                                    Button {
                                        withAnimation(.snappy(duration: 0.25)) { pendingDecline = row }
                                    } label: {
                                        Image(systemName: "calendar.badge.minus")
                                    }
                                    .tint(.red)
                                }
                                if row.isEditable {
                                    Button {
                                        beginEditing(row)
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .contextMenu {
                                if row.hasMeeting {
                                    Button {
                                        viewModel.openMeeting(rowID: row.id)
                                    } label: {
                                        Label("Join meeting", systemImage: "video")
                                    }
                                }
                                if row.isEditable {
                                    Button("Edit…") { beginEditing(row) }
                                }
                                if row.canDecline {
                                    Button("Decline…", role: .destructive) {
                                        withAnimation(.snappy(duration: 0.25)) { pendingDecline = row }
                                    }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .frame(height: min(max(estimatedListHeight, 44), maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        .animation(.snappy(duration: 0.3), value: rowSignature)
    }

    /// Changes when the set of visible rows changes, so insertions/removals
    /// (e.g. a declined event dropping out) animate.
    private var rowSignature: [String] {
        viewModel.sections.flatMap { $0.rows.map(\.id) }
    }

    /// The row that shows the blue highlight: only whatever the cursor is over,
    /// so it's a pure hover affordance. The current event stands out on its own
    /// (bright hours + pinned Join button) without holding the highlight.
    private var highlightedRowID: EventRow.ID? {
        hoveredRowID
    }

    private func dayHeader(_ section: DaySection, isFirst: Bool) -> some View {
        HStack(spacing: 5) {
            Text(section.title)
                .fontWeight(.semibold)
            Text(section.dateLabel)
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .textCase(nil)
        .padding(.top, isFirst ? 16 : 4)
        .padding(.bottom, 7)
        .padding(.horizontal, 16)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    /// Approximate height of the `List` so the pop-over sizes to its content
    /// until it hits `maxListHeight`. `List` has no intrinsic size inside a
    /// `MenuBarExtra` window, so unlike the old `ScrollView` we estimate rather
    /// than measure (a few points of slack is fine).
    private var estimatedListHeight: CGFloat {
        let headerH: CGFloat = 32
        let rowH: CGFloat = 32
        let emptyH: CGFloat = 32
        let separatorH: CGFloat = 21
        var total: CGFloat = 16
        for (index, section) in viewModel.sections.enumerated() {
            if index > 0 { total += separatorH }
            total += headerH
            total += section.rows.isEmpty ? emptyH : CGFloat(section.rows.count) * rowH
        }
        return total
    }

    private func beginEditing(_ row: EventRow) {
        guard let draft = viewModel.editDraft(rowID: row.id) else {
            NSSound.beep()
            return
        }
        withAnimation(nav) { editing = EditingSession(row: row, draft: draft) }
    }

    private func declineMessage(for row: EventRow) -> String {
        if google.hasUsableAccount {
            return "“\(row.title)” — you'll be marked as declined and the organizer will be notified. It will be removed from your list."
        }
        return "“\(row.title)” will be removed from your list. Connect a Google account in Settings if you want the organizer to be notified you declined."
    }

    /// Inline "are you sure?" card for the destructive Decline action, drawn as
    /// an overlay so it stays inside the pop-over window (an `alert` would risk
    /// dismissing the whole pop-over).
    private func declineConfirmation(_ row: EventRow) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { pendingDecline = nil } }
                .transition(.opacity)
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.minus")
                    .font(.system(size: 26))
                    .foregroundStyle(.red)
                Text("Decline this event?")
                    .font(.headline)
                Text(declineMessage(for: row))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Cancel") {
                        withAnimation(.snappy(duration: 0.2)) { pendingDecline = nil }
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Decline & Remove", role: .destructive) {
                        viewModel.declineEvent(rowID: row.id)
                        withAnimation(.snappy(duration: 0.2)) { pendingDecline = nil }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(nav) { showingSettings = true }
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

/// One event row: a status dot, the time range, the title, and — on hover or
/// for the current meeting — a Join button. Rows with a meeting link are
/// tap-to-join.
struct EventRowView: View {
    let row: EventRow
    /// True when this row currently holds the shared blue highlight.
    var isHighlighted: Bool = false
    /// Namespace of the shared highlight so it slides here from another row.
    var namespace: Namespace.ID?
    var onJoin: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }

    /// The Join button is pinned to the current meeting so it's always one
    /// click away; other rows stay tap-to-join without the button.
    private var showJoin: Bool { row.isNext }

    var body: some View {
        HStack(spacing: 11) {
            StatusDot(color: row.calendarColor, isAllDay: row.isAllDay, isInProgress: row.isInProgress)
            time
                .font(.callout.monospacedDigit())
                .frame(width: 92, alignment: .leading)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(row.isNext ? .semibold : .regular)
            Spacer(minLength: 6)
            // Pinned to the current event only, so ⌃J binds to a single button.
            if row.hasMeeting && showJoin {
                joinButton
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { onHoverChange($0) }
        .onTapGesture { if row.hasMeeting { onJoin() } }
        .help(row.hasMeeting ? "Join meeting" : "")
    }

    /// A single blue capsule shared across the list: only the highlighted row
    /// draws it, and the `matchedGeometryEffect` slides it here from wherever
    /// it was, so the highlight glides between rows rather than blinking.
    @ViewBuilder
    private var rowBackground: some View {
        if isHighlighted {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
            if let namespace {
                shape.matchedGeometryEffect(id: "row-highlight", in: namespace)
            } else {
                shape
            }
        }
    }

    /// One accent pill combining the camera glyph with a muted "⌃J" keycap, so
    /// the click affordance and its keyboard shortcut read as a single control.
    /// The shortcut is live only on the current event (the sole pinned button).
    private var joinButton: some View {
        Button(action: onJoin) {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.caption2)
                Text("⌃J")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("j", modifiers: .control)
        .help("Join meeting (⌃J)")
    }

    private var time: Text {
        // The current event's hours read bright (white); every other row's stay
        // muted, so the "now" row stands out without a persistent background.
        let color: Color = row.isNext ? .primary : .secondary
        if row.isAllDay {
            return Text("All day").foregroundStyle(color)
        }
        return Text("\(row.startTime) – \(row.endTime)").foregroundStyle(color)
    }
}

/// The calendar-colour marker at the start of a row. A filled dot for timed
/// events, a ring for all-day, and — for a meeting in progress — an expanding
/// "radar" pulse so the live event reads at a glance.
struct StatusDot: View {
    let color: Color
    let isAllDay: Bool
    let isInProgress: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isInProgress {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulse ? 2.0 : 1)
                    .opacity(pulse ? 0 : 0.6)
            }
            Group {
                if isAllDay {
                    Circle().strokeBorder(color, lineWidth: 2)
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: 10, height: 10)
        }
        .frame(width: 13, height: 13)
        .onAppear {
            guard isInProgress else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
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
                    Toggle("All-day", isOn: $draft.isAllDay.animation(.snappy(duration: 0.2)))
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
        VStack(alignment: .leading, spacing: 10) {
            Label("Calendar access denied", systemImage: "lock.fill")
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
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
    }
}
