import Foundation

/// Reads the progress text a model engine reports while it is fetched or readied.
public enum ModelProgressText {
    /// "loading" only counts at the start of a word: "Downloading" contains it too.
    private static let onDevicePatterns = ["\\bcompil", "\\bprepar", "\\bloading"]

    /// True when the text describes work done on the device (compiling or loading into memory),
    /// as opposed to bytes coming down from the network.
    public static func isOnDeviceWork(_ detail: String) -> Bool {
        onDevicePatterns.contains { detail.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
