import XCTest
@testable import DictationPolicyKit

final class ModelProgressTextTests: XCTestCase {
    func testLoadingAnAlreadyDownloadedModelIsOnDeviceWork() {
        let onDevice = [
            "Loading Whisper model...",
            "Loading downloaded Whisper model...",
            "Loading downloaded model...",
            "Compiling for this device",
            "Preparing model"
        ]
        for detail in onDevice {
            XCTAssertTrue(ModelProgressText.isOnDeviceWork(detail), detail)
        }
    }

    func testDownloadProgressIsNotOnDeviceWork() {
        let downloading = [
            "Downloading 3 of 9 files • 33%",
            "33% complete",
            "Downloading Whisper Turbo"
        ]
        for detail in downloading {
            XCTAssertFalse(ModelProgressText.isOnDeviceWork(detail), detail)
        }
    }
}
