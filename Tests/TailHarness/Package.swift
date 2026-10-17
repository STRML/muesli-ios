// swift-tools-version: 6.0
import PackageDescription

// Measures the trailing "Thank you." hallucination on a Mac with the real WhisperKit model, the same pinned
// revision and the same decode options the app uses (project.yml). Not part of CI: it needs the 626 MB model.
// The two kits are symlinks to the app's own sources, so the harness measures the code that ships.
//
//   cd Tests/TailHarness && swift run -c release tail-harness generate <fixtures-dir>
//   swift run -c release tail-harness run --fixtures <dir> --models <dir> --out results.jsonl --prep trim
//   swift run -c release tail-harness report results.jsonl
//
// See Tests/TailHarness/README.md.
let package = Package(
    name: "TailHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", revision: "80d96762fa727f816ffceab76a6529cd12c2726f"),
    ],
    targets: [
        .target(name: "DictationPolicyKit", path: "Sources/DictationPolicyKit"),
        .target(name: "ClipFixtureKit", path: "Sources/ClipFixtureKit"),
        .executableTarget(
            name: "tail-harness",
            dependencies: [
                "DictationPolicyKit",
                "ClipFixtureKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/TailHarness",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
