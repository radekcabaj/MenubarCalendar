import AppKit
import Foundation

/// Persistent user settings backed by `UserDefaults` (PRD §3.5, §3.4).
///
/// `selectedCalendarIDs == nil` means "all calendars" — the first-run default.
/// Once the user touches the calendar list the concrete set is materialised and
/// stored, so an empty set correctly means "nothing selected" rather than "all".
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
        static let openInChromeProfile = "openInChromeProfile"
        static let preferredChromeProfileDirectory = "preferredChromeProfileDirectory"
    }

    private let defaults: UserDefaults

    @Published private(set) var selectedCalendarIDs: Set<String>?

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

    /// Open meeting links in the Chrome profile that matches the event's account.
    @Published var openInChromeProfile: Bool {
        didSet { defaults.set(openInChromeProfile, forKey: Keys.openInChromeProfile) }
    }

    /// When non-empty, always open meeting links in this Chrome profile
    /// directory (e.g. `"Profile 1"`), overriding the account-email match.
    /// Empty means "match automatically to the event's account".
    @Published var preferredChromeProfileDirectory: String {
        didSet { defaults.set(preferredChromeProfileDirectory, forKey: Keys.preferredChromeProfileDirectory) }
    }

    init(defaults: UserDefaults = .standard) {
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
        self.openInChromeProfile = defaults.object(forKey: Keys.openInChromeProfile) as? Bool ?? true
        self.preferredChromeProfileDirectory = defaults.string(forKey: Keys.preferredChromeProfileDirectory) ?? ""
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

    /// Whether a calendar is included in queries. Unknown / first-run → true.
    func isSelected(_ id: String) -> Bool {
        selectedCalendarIDs?.contains(id) ?? true
    }

    /// Toggle a calendar. `allIDs` seeds the set on first change so that
    /// deselecting one calendar keeps the rest selected.
    func setSelected(_ id: String, selected: Bool, allIDs: [String]) {
        var set = selectedCalendarIDs ?? Set(allIDs)
        if selected {
            set.insert(id)
        } else {
            set.remove(id)
        }
        selectedCalendarIDs = set
        defaults.set(Array(set), forKey: Keys.selectedCalendarIDs)
    }
}
