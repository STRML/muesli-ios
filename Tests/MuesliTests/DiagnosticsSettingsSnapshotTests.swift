import SwiftUI
import XCTest
@testable import Muesli

/// Renders the Diagnostics section of About for each way its address can resolve, so the screen can be reviewed
/// without a phone. Skipped unless `MUESLI_DIAGNOSTICS_SNAPSHOT_DIR` is set (through xcodebuild:
/// `TEST_RUNNER_MUESLI_DIAGNOSTICS_SNAPSHOT_DIR=/some/dir`).
@MainActor
final class DiagnosticsSettingsSnapshotTests: XCTestCase {
    private struct Scene {
        var name: String
        var summaries: String
        var override: String
    }

    func testRenderDiagnosticsSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["MUESLI_DIAGNOSTICS_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set MUESLI_DIAGNOSTICS_SNAPSHOT_DIR to render the Diagnostics settings")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keys = [
            MuesliPreferences.diagnosticsShippingEnabledKey, MuesliPreferences.diagnosticsAcknowledgedHostKey,
            MuesliPreferences.customLLMBaseURLKey, MuesliPreferences.diagnosticsEndpointURLKey,
        ]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        let scenes = [
            Scene(name: "from-ai-summaries", summaries: "https://studio.tail13013.ts.net/v1", override: ""),
            Scene(name: "own-field", summaries: "https://studio.tail13013.ts.net/v1", override: "https://logs.home.ts.net/v1"),
            Scene(name: "own-field-invalid", summaries: "https://studio.tail13013.ts.net/v1", override: "logs.home.ts.net"),
            Scene(name: "public-host", summaries: "", override: "https://logs.example.com"),
            Scene(name: "nothing-set", summaries: "", override: ""),
        ]
        for scene in scenes {
            UserDefaults.standard.set(true, forKey: MuesliPreferences.diagnosticsShippingEnabledKey)
            UserDefaults.standard.removeObject(forKey: MuesliPreferences.diagnosticsAcknowledgedHostKey)
            UserDefaults.standard.set(scene.summaries, forKey: MuesliPreferences.customLLMBaseURLKey)
            UserDefaults.standard.set(scene.override, forKey: MuesliPreferences.diagnosticsEndpointURLKey)
            for style in [UIUserInterfaceStyle.dark, .light] {
                let size = CGSize(width: 393, height: 980)
                let host = UIHostingController(
                    rootView: ScrollView { DiagnosticsShippingSettings().padding(16) }.background(MuesliTheme.backgroundBase)
                )
                host.view.frame = CGRect(origin: .zero, size: size)
                host.overrideUserInterfaceStyle = style
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.overrideUserInterfaceStyle = style
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                let suffix = style == .dark ? "dark" : "light"
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(scene.name)-\(suffix).png"))
                window.isHidden = true
            }
        }
    }
}
