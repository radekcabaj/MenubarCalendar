import AppKit
import Foundation

/// One Chrome profile: its directory, human-readable name, primary (sync)
/// account, and every signed-in account.
struct ChromeProfile: Equatable {
    let directory: String
    let name: String?
    let primaryEmail: String?
    let accountEmails: [String]

    /// Label for the picker: the profile's name, else its directory.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return directory
    }
}

/// Maps an account email to a Google Chrome profile and opens URLs in it.
///
/// Chrome lists profile directories + the primary account in `Local State`
/// (`profile.info_cache` → `user_name`); each profile's *other* signed-in
/// accounts live in `<Profile>/Preferences` → `account_info[].email`. Since an
/// account (like a Workspace address) is often a *secondary* account inside a
/// profile, we scan both. Opening is done by invoking the Chrome binary with
/// `--profile-directory=<dir>`. The `authuser=<email>` rewrite that picks the
/// right account *within* a profile is separate — see
/// `EventLinkExtractor.accountURL(_:authuserEmail:)`.
enum ChromeProfileResolver {
    static var chromeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
    }
    static var localStateURL: URL { chromeDirectory.appendingPathComponent("Local State") }

    // MARK: - Parsing (pure / testable)

    /// `[profile directory: primary email?]` from a `Local State` blob.
    static func primaryEmails(fromLocalState data: Data) -> [String: String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = json["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }

        var result: [String: String] = [:]
        for (directory, raw) in cache {
            if let info = raw as? [String: Any],
               let email = info["user_name"] as? String, !email.isEmpty {
                result[directory] = email
            } else {
                result[directory] = "" // known directory, no primary account
            }
        }
        return result
    }

    /// `[profile directory: human-readable name]` from a `Local State` blob.
    static func displayNames(fromLocalState data: Data) -> [String: String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = json["profile"] as? [String: Any],
            let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }

        var result: [String: String] = [:]
        for (directory, raw) in cache {
            if let info = raw as? [String: Any],
               let name = info["name"] as? String, !name.isEmpty {
                result[directory] = name
            }
        }
        return result
    }

    /// All signed-in account emails from a profile's `Preferences` blob.
    static func accountEmails(fromPreferences data: Data) -> [String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accounts = json["account_info"] as? [[String: Any]]
        else { return [] }
        return accounts.compactMap { $0["email"] as? String }.filter { !$0.isEmpty }
    }

    /// Choose the best profile for `email`:
    /// 0. an override the user pinned for this account in Settings, else
    /// 1. a profile where it's the primary account, else
    /// 2. the (unique) profile where it's a signed-in secondary account, else
    /// 3. if it's in several profiles, the first by directory name (deterministic).
    ///
    /// `overrides` maps an account email to a profile directory. An override
    /// pointing at a profile that no longer exists is ignored, so deleting a
    /// Chrome profile falls back to automatic matching instead of failing.
    static func resolveProfileDirectory(
        forEmail email: String,
        profiles: [ChromeProfile],
        overrides: [String: String] = [:]
    ) -> String? {
        let target = email.lowercased()
        let pinned = overrides.first { $0.key.lowercased() == target }?.value
        if let pinned, profiles.contains(where: { $0.directory == pinned }) {
            return pinned
        }
        if let primary = profiles.first(where: { $0.primaryEmail?.lowercased() == target }) {
            return primary.directory
        }
        let matches = profiles
            .filter { $0.accountEmails.contains { $0.lowercased() == target } }
            .sorted { $0.directory < $1.directory }
        return matches.first?.directory
    }

    // MARK: - Disk + launch (side-effecting)

    static func loadProfiles() -> [ChromeProfile] {
        guard let stateData = try? Data(contentsOf: localStateURL) else { return [] }
        let names = displayNames(fromLocalState: stateData)
        return primaryEmails(fromLocalState: stateData).map { directory, primary in
            let prefsURL = chromeDirectory
                .appendingPathComponent(directory)
                .appendingPathComponent("Preferences")
            var accounts = (try? Data(contentsOf: prefsURL)).map(accountEmails(fromPreferences:)) ?? []
            if !primary.isEmpty, !accounts.contains(where: { $0.lowercased() == primary.lowercased() }) {
                accounts.append(primary)
            }
            return ChromeProfile(
                directory: directory,
                name: names[directory],
                primaryEmail: primary.isEmpty ? nil : primary,
                accountEmails: accounts
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func profileDirectory(forEmail email: String, overrides: [String: String] = [:]) -> String? {
        resolveProfileDirectory(forEmail: email, profiles: loadProfiles(), overrides: overrides)
    }

    static func chromeExecutableURL() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            return nil
        }
        return app.appendingPathComponent("Contents/MacOS/Google Chrome")
    }

    /// The command line that opens `url`, optionally pinned to a profile.
    static func arguments(
        executablePath: String, url: URL, profileDirectory: String?
    ) -> [String] {
        var arguments = [executablePath]
        if let profileDirectory, !profileDirectory.isEmpty {
            arguments.append("--profile-directory=\(profileDirectory)")
        }
        arguments.append(url.absoluteString)
        return arguments
    }

    /// Open `url` in Chrome. `profileDirectory` pins a specific profile; when
    /// nil, Chrome uses whichever profile it opened last. `url` is expected to
    /// already carry any `authuser` rewrite. Returns false if Chrome isn't
    /// installed or couldn't be reached, so the caller can fall back.
    ///
    /// A running Chrome is handed the command line over its singleton socket
    /// rather than by starting a second process: both end up in the same
    /// browser, but spawning one makes macOS add a duplicate "Google Chrome"
    /// tile to the Dock (see `ChromeSingleton`). Launching is the fallback —
    /// for a cold start it *is* the right thing, and that instance becomes the
    /// browser, so it leaves no stray tile either.
    @discardableResult
    static func open(_ url: URL, profileDirectory: String?) -> Bool {
        guard let executable = chromeExecutableURL() else { return false }
        let arguments = arguments(
            executablePath: executable.path, url: url, profileDirectory: profileDirectory
        )

        if let socketPath = ChromeSingleton.socketPath(inUserDataDirectory: chromeDirectory),
           ChromeSingleton.send(arguments: arguments, socketPath: socketPath) {
            return true
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = Array(arguments.dropFirst()) // argv[0] is the binary itself
        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }
}
