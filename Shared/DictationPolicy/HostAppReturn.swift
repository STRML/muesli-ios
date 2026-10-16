import Foundation

/// Spike: sending the user back to the app they were typing in once a keyboard-started recording is running.
///
/// iOS has no public "go back" call, so this works only for host apps that register a URL scheme. The keyboard
/// reports the host's bundle id on the launch URL; the app looks that id up here. An unknown, malformed or
/// missing host, or the setting being off, yields no URL, which is exactly today's behaviour (the user swipes back).
enum HostAppReturn {
    /// Query item the keyboard adds to its launch URL. Old URLs without it keep working.
    static let hostQueryItem = "host"

    struct Entry: Equatable, Sendable {
        let bundleID: String
        let name: String
        let url: URL
        /// True only when the scheme was proven to open the app. Everything else comes from the app's own docs
        /// or well-known scheme lists and still needs a device check.
        let verified: Bool
    }

    /// Safari is deliberately absent: it has no scheme that opens it without navigating (`http(s)` opens the
    /// default browser at a page), so there is no return target for it.
    static let table: [Entry] = [
        entry("com.apple.MobileSMS", "Messages", "sms://"),
        entry("com.apple.mobilenotes", "Notes", "mobilenotes://"),
        entry("com.apple.mobilemail", "Mail", "message://"),
        entry("net.whatsapp.WhatsApp", "WhatsApp", "whatsapp://"),
        entry("ph.telegra.Telegraph", "Telegram", "tg://"),
        entry("com.tinyspeck.chatlyio", "Slack", "slack://open"),
        entry("com.hammerandchisel.discord", "Discord", "discord://"),
        entry("org.whispersystems.signal", "Signal", "sgnl://"),
        entry("com.facebook.Messenger", "Messenger", "fb-messenger://"),
        entry("com.burbn.instagram", "Instagram", "instagram://"),
        entry("com.atebits.Tweetie2", "X", "twitter://"),
        entry("notion.id", "Notion", "notion://"),
        entry("md.obsidian", "Obsidian", "obsidian://"),
        entry("com.microsoft.skype.teams", "Teams", "msteams://"),
        entry("com.microsoft.Office.Outlook", "Outlook", "ms-outlook://"),
        entry("com.google.Gmail", "Gmail", "googlegmail://"),
        entry("com.openai.chat", "ChatGPT", "chatgpt://"),
        entry("com.anthropic.claude", "Claude", "claude://"),
        entry("com.google.chrome.ios", "Chrome", "googlechrome://")
    ]

    private static func entry(_ bundleID: String, _ name: String, _ url: String, verified: Bool = false) -> Entry {
        Entry(bundleID: bundleID, name: name, url: URL(string: url)!, verified: verified)
    }

    /// A reverse-DNS bundle id: letters, digits, `-` and `.`, at least two non-empty segments, bounded length.
    /// Anything else is treated as "no host" rather than echoed into a URL.
    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw
        guard (3...155).contains(id.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return id
    }

    /// The launch URL with the host bundle id added. An unusable id returns the URL unchanged.
    static func appendingHost(_ hostBundleID: String?, to url: URL) -> URL {
        guard let host = sanitized(hostBundleID),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != hostQueryItem }
        items.append(URLQueryItem(name: hostQueryItem, value: host))
        components.queryItems = items
        return components.url ?? url
    }

    /// The host bundle id carried by a launch URL, or nil when absent or malformed.
    static func hostBundleID(in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return sanitized(items?.first(where: { $0.name == hostQueryItem })?.value)
    }

    /// Where to send the user, or nil to do nothing. `ownBundleIDs` keeps Muesli from "returning" to itself.
    static func returnURL(
        forHost hostBundleID: String?,
        enabled: Bool,
        ownBundleIDs: Set<String> = []
    ) -> URL? {
        guard enabled, let host = sanitized(hostBundleID), !ownBundleIDs.contains(host) else { return nil }
        return table.first { $0.bundleID.caseInsensitiveCompare(host) == .orderedSame }?.url
    }
}
