import SwiftUI

/// Settings screen shown inside the pop-over (PRD §3.4, §3.5, §3.6):
/// all-day toggle, launch-at-login toggle, and per-calendar checkboxes.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var google: GoogleCalendarService
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    googleSection
                    Divider()
                    generalSection
                    Divider()
                    shortcutSection
                    Divider()
                    calendarsSection
                }
                .padding(16)
            }
            .frame(maxHeight: 360)
        }
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        ZStack {
            Text("Ustawienia").font(.headline).fontWeight(.medium)
            Button {
                onBack()
            } label: {
                Label("Wstecz", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ogólne")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Pokazuj wydarzenia całodniowe", isOn: $settings.showAllDay)

            Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))

            if let error = loginItem.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skrót do spotkania")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Globalny skrót klawiszowy", isOn: $settings.hotKeyEnabled)

            HStack {
                Text("Otwórz najbliższe spotkanie")
                Spacer()
                ShortcutRecorder()
            }
            .disabled(!settings.hotKeyEnabled)
            .opacity(settings.hotKeyEnabled ? 1 : 0.5)

            Text("Otwiera link do spotkania z wydarzenia w pasku menu. Gdy brak linku — otwiera aplikację Kalendarz.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Otwieraj w dopasowanym profilu Chrome", isOn: $settings.openInChromeProfile)

            Text("Dopasowuje profil Chrome do konta, na którym jest spotkanie (np. radek@tonik.com). Gdy brak dopasowania — otwiera w domyślnej przeglądarce.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Odrzucanie wydarzeń (Google)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !google.isConfigured {
                Text("Integracja Google nie jest skonfigurowana w tej wersji aplikacji.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if google.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(google.accountEmail ?? "Połączono z Google")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Odłącz") { google.disconnect() }
                }
                Text("Odrzucenie wydarzenia powiadomi organizatora (także dla kalendarzy udostępnionych z prawem edycji).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    Task { await google.connect() }
                } label: {
                    if google.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Połącz konto Google…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(google.isBusy)
                Text("Bez połączenia odrzucenie tylko usuwa wydarzenie z Twojego widoku — organizator nie zostanie powiadomiony.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = google.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var calendarsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kalendarze")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if viewModel.availableCalendars.isEmpty {
                Text("Brak kalendarzy")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.availableCalendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { settings.isSelected(calendar.id) },
                        set: { newValue in
                            settings.setSelected(
                                calendar.id,
                                selected: newValue,
                                allIDs: viewModel.availableCalendars.map(\.id)
                            )
                        }
                    )) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(calendar.color)
                                .frame(width: 8, height: 8)
                            Text(calendar.title)
                        }
                    }
                }
            }
        }
    }
}
