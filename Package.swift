// swift-tools-version: 6.0
import PackageDescription

// Host-testable slice of the app: the remote transcription decision logic and its HTTP client, and the
// two-pass dictation policy (which text is inserted, and what the keyboard preview shows). The same sources
// are compiled into the Muesli targets through project.yml's `Shared` path; this package exists so
// `swift test` can run them on a Mac without an iOS Simulator.
let package = Package(
    name: "RemoteTranscriptionKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RemoteTranscriptionKit", targets: ["RemoteTranscriptionKit"]),
        // Exported for Tests/TailHarness, a separate package that runs the real WhisperKit model on a Mac.
        .library(name: "DictationPolicyKit", targets: ["DictationPolicyKit"]),
        .library(name: "ClipFixtureKit", targets: ["ClipFixtureKit"]),
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
        // Synthetic and `say`-generated test audio; nothing here is a recording of a person.
        .target(
            name: "ClipFixtureKit",
            path: "Tests/ClipFixtureKit"
        ),
        .testTarget(
            name: "DictationPolicyKitTests",
            dependencies: ["DictationPolicyKit", "ClipFixtureKit"],
            path: "Tests/DictationPolicyKitTests"
        ),
    ]
)
