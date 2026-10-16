// swift-tools-version: 6.0
import PackageDescription

// Host-testable slice of the app: the remote transcription decision logic and its HTTP client. The same
// sources are compiled into the Muesli targets through project.yml's `Shared` path; this package exists so
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
    ]
)
