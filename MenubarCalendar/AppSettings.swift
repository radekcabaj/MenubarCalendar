import AppKit
import Foundation

/// Where events come from — one per install, never both at once (spec
/// 2026-10-02). `.google` polls the Google Calendar API directly; `.eventKit`
/// reads whatever accounts macOS's Calendar database has.
enum DataSource: String, CaseIterable {
    case google
    case eventKit
}

/// Persistent user settings backed by `UserDefaults` (PRD §3.5, §3.4).
///
/// `selectedCalendarIDs` / `selectedGoogleCalendarIDs == nil` means "defaults"
/// — the first-run default for that source. Once the user touches the calendar
/// list, the concrete set is materialised and stored, so an empty set correctly
/// means "nothing selected" rather than "all".
/// Launch-at-login is intentionally *not* stored here: `SMAppService` is the
/// source of truth for that (see `LoginItemManager`).
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let selectedCalendarIDs = "selectedCalendarIDs"
        static let showAllDay = "showAllDay"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifierRaw = "hotKeyModifierRaw"
        static let hotKeyCharacter = "hotKeyCharacter"
        static let chromeProfileOverrides = "chromeProfileOverrides"
        static let dataSource = "dataSource"
        static let selectedGoogleCalendarIDs = "selectedGoogleCalendarIDs"
    }

    private let defaults: UserDefaults

    @Published private(set) var selectedCalendarIDs: Set<String>?

    /// Like `selectedCalendarIDs`, for Google calendars (`"<email>/<calendarId>"`).
    /// `nil` means "use each calendar's default" (its Google-side selection).
    @Published private(set) var selectedGoogleCalendarIDs: Set<String>?

    @Published var dataSource: DataSource {
        didSet { defaults.set(dataSource.rawValue, forKey: Keys.dataSource) }
    }

    @Published var showAllDay: Bool {
        didSet { defaults.set(showAllDay, forKey: Keys.showAllDay) }
    }

    // MARK: Global hot key (open next meeting) — default ⌃⌥⌘M

    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    @Published private(set) var hotKeyKeyCode: Int
    @Published private(set) var hotKeyModifierRaw: UInt
    @Published private(set) var hotKeyCharacter: String

    // MARK: Chrome profile per account

    /// Chrome profile directory pinned per account email, e.g.
    /// `["radek@tonik.com": "Default"]`. Accounts with no entry are matched
    /// automatically against the profiles Chrome has signed in.
    @Published private(set) var chromeProfileOverrides: [String: String]

    /// `isExistingInstall` is true when this Mac already granted the app
    /// calendar access — i.e. someone was using the EventKit source before the
    /// switch existed. Only consulted the first time; the result is stored.
    init(defaults: UserDefaults = .standard, isExistingInstall: Bool = false) {
        self.defaults = defaults

        if let stored = defaults.array(forKey: Keys.selectedCalendarIDs) as? [String] {
            self.selectedCalendarIDs = Set(stored)
        } else {
            self.selectedCalendarIDs = nil
        }

        if defaults.object(forKey: Keys.showAllDay) == nil {
            self.showAllDay = true // default on (PRD §3.4)
        } else {
            self.showAllDay = defaults.bool(forKey: Keys.showAllDay)
        }

        self.hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        self.hotKeyKeyCode = defaults.object(forKey: Keys.hotKeyKeyCode) as? Int ?? 46 // kVK_ANSI_M
        if let raw = defaults.object(forKey: Keys.hotKeyModifierRaw) as? Int {
            self.hotKeyModifierRaw = UInt(raw)
        } else {
            self.hotKeyModifierRaw = NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        }
        self.hotKeyCharacter = defaults.string(forKey: Keys.hotKeyCharacter) ?? "M"
        self.chromeProfileOverrides =
            defaults.dictionary(forKey: Keys.chromeProfileOverrides) as? [String: String] ?? [:]

        if let stored = defaults.array(forKey: Keys.selectedGoogleCalendarIDs) as? [String] {
            self.selectedGoogleCalendarIDs = Set(stored)
        } else {
            self.selectedGoogleCalendarIDs = nil
        }

        if let raw = defaults.string(forKey: Keys.dataSource), let stored = DataSource(rawValue: raw) {
            self.dataSource = stored
        } else {
            let existing = isExistingInstall || defaults.object(forKey: Keys.selectedCalendarIDs) != nil
            let initial: DataSource = existing ? .eventKit : .google
            defaults.set(initial.rawValue, forKey: Keys.dataSource)
            self.dataSource = initial
        }
    }

    /// The profile pinned for `email`, if any. Nil means "match automatically".
    func chromeProfileOverride(forEmail email: String) -> String? {
        chromeProfileOverrides.first { $0.key.lowercased() == email.lowercased() }?.value
    }

    /// Pin `email` to a Chrome profile directory. Passing nil clears the pin and
    /// returns the account to automatic matching.
    func setChromeProfileOverride(_ directory: String?, forEmail email: String) {
        var map = chromeProfileOverrides
        for key in map.keys where key.lowercased() == email.lowercased() {
            map.removeValue(forKey: key)
        }
        if let directory, !directory.isEmpty {
            map[email] = directory
        }
        chromeProfileOverrides = map
        defaults.set(map, forKey: Keys.chromeProfileOverrides)
    }

    /// The current hot key as modifier flags.
    var hotKeyModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: hotKeyModifierRaw)
    }

    /// Human-readable shortcut, e.g. `⌃⌥⌘M`.
    var hotKeyDisplayString: String {
        let flags = hotKeyModifierFlags
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option)  { symbols += "⌥" }
        if flags.contains(.shift)   { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols + hotKeyCharacter
    }

    func setHotKey(keyCode: Int, modifierRaw: UInt, character: String) {
        hotKeyKeyCode = keyCode
        hotKeyModifierRaw = modifierRaw
        hotKeyCharacter = character
        defaults.set(keyCode, forKey: Keys.hotKeyKeyCode)
        defaults.set(Int(modifierRaw), forKey: Keys.hotKeyModifierRaw)
        defaults.set(character, forKey: Keys.hotKeyCharacter)
    }

    /// Whether a calendar is included. Before the user has touched that
    /// source's list, `defaultValue` decides (true for EventKit; the calendar's
    /// Google-side selection for Google).
    func isSelected(_ id: String, in source: DataSource, default defaultValue: Bool = true) -> Bool {
        selection(for: source)?.contains(id) ?? defaultValue
    }

    /// Toggle a calendar. `currentlySelected` seeds the set on the first change
    /// so the rest of the list keeps its current state.
    func setSelected(_ id: String, selected: Bool, in source: DataSource, currentlySelected: [String]) {
        var set = selection(for: source) ?? Set(currentlySelected)
        if selected {
            set.insert(id)
        } else {
            set.remove(id)
        }
        switch source {
        case .eventKit:
            selectedCalendarIDs = set
            defaults.set(Array(set), forKey: Keys.selectedCalendarIDs)
        case .google:
            selectedGoogleCalendarIDs = set
            defaults.set(Array(set), forKey: Keys.selectedGoogleCalendarIDs)
        }
    }

    private func selection(for source: DataSource) -> Set<String>? {
        switch source {
        case .eventKit: selectedCalendarIDs
        case .google: selectedGoogleCalendarIDs
        }
    }
}
