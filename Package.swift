// swift-tools-version: 6.0
import PackageDescription

// Host-testable slice of the app: the remote transcription decision logic and its HTTP client, and the
// two-pass dictation policy (which text is inserted, and what the keyboard preview shows), the keyboard's
// typing logic (layout, shift, autocapitalization, word-at-cursor, suggestions), and the diagnostics shipping
// logic (log parser, allowlist sanitizer, durable upload queue). The same sources
// are compiled into the Muesli targets through project.yml's `Shared` path; this package exists so
// `swift test` can run them on a Mac without an iOS Simulator.
let package = Package(
    name: "RemoteTranscriptionKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RemoteTranscriptionKit", targets: ["RemoteTranscriptionKit"]),
    ],
    targets: [
        .target(
            name: "RemoteTranscriptionKit",
            path: "Shared/RemoteTranscription"
        ),
        .testTarget(
            name: "RemoteTranscriptionKitTests",
            dependencies: ["RemoteTranscriptionKit"],
            path: "Tests/RemoteTranscriptionKitTests"
        ),
        .target(
            name: "DictationPolicyKit",
            path: "Shared/DictationPolicy"
        ),
        .testTarget(
            name: "DictationPolicyKitTests",
            dependencies: ["DictationPolicyKit"],
            path: "Tests/DictationPolicyKitTests"
        ),
        .target(
            name: "KeyboardTypingKit",
            path: "Shared/KeyboardTyping"
        ),
        .testTarget(
            name: "KeyboardTypingKitTests",
            dependencies: ["KeyboardTypingKit"],
            path: "Tests/KeyboardTypingKitTests",
            exclude: ["Corpus/README.md"]
        ),
        .target(
            name: "DiagnosticsKit",
            path: "Shared/DiagnosticsShipping"
        ),
        .testTarget(
            name: "DiagnosticsKitTests",
            dependencies: ["DiagnosticsKit"],
            path: "Tests/DiagnosticsKitTests"
        ),
    ]
)
