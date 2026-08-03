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
/// `--profile-directory=<dir>`; for Google links we also add `authuser=<email>`
/// so the right account is used within a multi-account profile.
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
    /// 1. a profile where it's the primary account, else
    /// 2. the (unique) profile where it's a signed-in secondary account, else
    /// 3. if it's in several profiles, the first by directory name (deterministic).
    static func resolveProfileDirectory(forEmail email: String, profiles: [ChromeProfile]) -> String? {
        let target = email.lowercased()
        if let primary = profiles.first(where: { $0.primaryEmail?.lowercased() == target }) {
            return primary.directory
        }
        let matches = profiles
            .filter { $0.accountEmails.contains { $0.lowercased() == target } }
            .sorted { $0.directory < $1.directory }
        return matches.first?.directory
    }

    /// Add/replace `authuser=<email>` on Google URLs so the right account is
    /// used inside a multi-account profile. Non-Google URLs are returned as-is.
    static func googleURL(_ url: URL, authuserEmail: String) -> URL {
        guard let host = url.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "authuser" }
        items.append(URLQueryItem(name: "authuser", value: authuserEmail))
        components.queryItems = items
        return components.url ?? url
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

    static func profileDirectory(forEmail email: String) -> String? {
        resolveProfileDirectory(forEmail: email, profiles: loadProfiles())
    }

    static func chromeExecutableURL() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            return nil
        }
        return app.appendingPathComponent("Contents/MacOS/Google Chrome")
    }

    /// Open `url` in the given Chrome profile (adding `authuser` for Google
    /// links). Returns false if Chrome couldn't be launched.
    @discardableResult
    static func open(_ url: URL, profileDirectory: String, accountEmail: String?) -> Bool {
        guard let executable = chromeExecutableURL() else { return false }
        let finalURL = accountEmail.map { googleURL(url, authuserEmail: $0) } ?? url
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--profile-directory=\(profileDirectory)", finalURL.absoluteString]
        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }
}
