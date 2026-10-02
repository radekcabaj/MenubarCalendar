import SwiftUI

/// Settings screen shown inside the pop-over (PRD §3.4, §3.5, §3.6):
/// all-day toggle, launch-at-login toggle, and per-calendar checkboxes.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var google: GoogleAccountStore
    let onBack: () -> Void

    /// Chrome profiles read from disk when the screen appears.
    @State private var chromeProfiles: [ChromeProfile] = []
    /// Chrome's profile list couldn't be read — see `loadChromeProfiles`.
    @State private var chromeProfilesUnreadable = false

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
                    chromeSection
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

            Text("Otwiera link do spotkania z wydarzenia w pasku menu — w Chrome, w profilu przypisanym do konta wydarzenia. Gdy brak linku — otwiera aplikację Kalendarz.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Konta Google")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !google.isConfigured {
                Text("Integracja Google nie jest skonfigurowana w tej wersji aplikacji.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(google.accounts) { account in
                    HStack(spacing: 8) {
                        Image(systemName: account.needsReconnect
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(account.needsReconnect ? .orange : .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.email)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let caption = accountCaption(account) {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if account.needsReconnect {
                            Button("Połącz ponownie") { Task { await google.addAccount() } }
                                .disabled(google.isBusy)
                        }
                        Button("Usuń") { google.remove(email: account.email) }
                    }
                }

                Button {
                    Task { await google.addAccount() }
                } label: {
                    if google.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Dodaj konto Google…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(google.isBusy)

                Text("Odrzucenie wydarzenia przez połączone konto powiadomi organizatora (także dla kalendarzy udostępnionych z prawem edycji). Bez konta odrzucenie tylko usuwa wydarzenie z Twojego widoku.")
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

    private func accountCaption(_ account: GoogleAccount) -> String? {
        if account.needsReconnect { return "Wymaga ponownego połączenia" }
        guard let lastSync = account.lastSync else { return nil }
        return "Ostatnia synchronizacja: \(lastSync.formatted(date: .omitted, time: .shortened))"
    }

    private var chromeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profil Chrome dla konta")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if chromeProfilesUnreadable {
                Text("macOS nie pozwala tej aplikacji czytać danych Chrome, więc nie wiadomo, do którego profilu należy konto — spotkanie otworzy się w profilu, który akurat jest na wierzchu. Włącz Pełny dostęp do dysku dla MenubarCalendar i uruchom ją ponownie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Otwórz Pełny dostęp do dysku") {
                    if let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            } else if chromeProfiles.isEmpty {
                Text("Nie znaleziono profili Chrome. Linki otworzą się w domyślnej przeglądarce.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.accountEmails.isEmpty {
                Text("Brak kont do przypisania.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.accountEmails, id: \.self) { email in
                    HStack(spacing: 8) {
                        Text(email)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Picker("", selection: chromeProfileBinding(for: email)) {
                            Text(automaticLabel(for: email)).tag("")
                            ForEach(chromeProfiles, id: \.directory) { profile in
                                Text(profile.displayName).tag(profile.directory)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                    }
                }

                Text("Spotkanie otwiera się w profilu Chrome, do którego zalogowane jest konto wydarzenia. Wybierz profil ręcznie, jeśli dopasowanie jest błędne.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: loadChromeProfiles)
    }

    /// A blocked read is not the same as "Chrome has no profiles": macOS denies
    /// one app the other's data unless it has Full Disk Access, and silently, so
    /// without saying it here the only symptom is meetings opening in the wrong
    /// profile.
    private func loadChromeProfiles() {
        do {
            chromeProfiles = try ChromeProfileResolver.loadProfiles()
            chromeProfilesUnreadable = false
        } catch {
            chromeProfiles = []
            chromeProfilesUnreadable = true
        }
    }

    /// Reads/writes the pinned profile for one account. Empty tag == automatic.
    private func chromeProfileBinding(for email: String) -> Binding<String> {
        Binding(
            get: { settings.chromeProfileOverride(forEmail: email) ?? "" },
            set: { settings.setChromeProfileOverride($0.isEmpty ? nil : $0, forEmail: email) }
        )
    }

    /// Names the profile automatic matching would pick, so the default option
    /// shows what it actually resolves to.
    private func automaticLabel(for email: String) -> String {
        guard
            let directory = ChromeProfileResolver.resolveProfileDirectory(
                forEmail: email, profiles: chromeProfiles
            ),
            let profile = chromeProfiles.first(where: { $0.directory == directory })
        else { return "Automatycznie" }
        return "Automatycznie (\(profile.displayName))"
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
                        get: { settings.isSelected(calendar.id, in: .eventKit) },
                        set: { newValue in
                            settings.setSelected(
                                calendar.id,
                                selected: newValue,
                                in: .eventKit,
                                currentlySelected: viewModel.availableCalendars
                                    .filter { settings.isSelected($0.id, in: .eventKit) }
                                    .map(\.id)
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
