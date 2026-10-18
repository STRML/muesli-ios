import XCTest
@testable import Muesli

/// The strings Settings computes from real settings, and the reasons it prints beside rows that cannot be used.
/// Pure logic: no views, no defaults.
final class SettingsPresentationTests: XCTestCase {
    // MARK: Execution and Processing never overclaim

    func testExecutionSaysOnDeviceOnlyWhenNoAudioCanLeave() {
        XCTAssertEqual(SettingsPresentation.executionLabel(remoteProcessingActive: false), "On device")
        let remote = SettingsPresentation.executionLabel(remoteProcessingActive: true)
        XCTAssertNotEqual(remote, "On device")
        XCTAssertTrue(remote.contains("your server"), remote)
    }

    func testSummaryDestinationIsNoneUnlessSummariesAreOn() {
        for backend in MeetingSummaryBackend.allCases {
            XCTAssertEqual(SettingsPresentation.summaryDestination(summariesEnabled: false, backend: backend), .none)
        }
        XCTAssertEqual(SettingsPresentation.summaryDestination(summariesEnabled: true, backend: .customLLM), .yourServer)
        XCTAssertEqual(SettingsPresentation.summaryDestination(summariesEnabled: true, backend: .openRouter), .openRouter)
        XCTAssertEqual(SettingsPresentation.summaryDestination(summariesEnabled: true, backend: .chatGPT), .chatGPT)
    }

    func testAboutProcessingNamesEveryPlaceDataCanGo() {
        XCTAssertEqual(
            SettingsPresentation.aboutProcessing(remoteProcessingActive: false, summaryDestination: .none),
            "On device"
        )
        XCTAssertEqual(
            SettingsPresentation.aboutProcessing(remoteProcessingActive: false, summaryDestination: .yourServer),
            "On device; summaries on your server"
        )
        XCTAssertEqual(
            SettingsPresentation.aboutProcessing(remoteProcessingActive: false, summaryDestination: .openRouter),
            "On device; summaries sent to OpenRouter"
        )
        XCTAssertEqual(
            SettingsPresentation.aboutProcessing(remoteProcessingActive: false, summaryDestination: .chatGPT),
            "On device; summaries sent to OpenAI"
        )
        XCTAssertEqual(
            SettingsPresentation.aboutProcessing(remoteProcessingActive: true, summaryDestination: .none),
            "On device, or your server"
        )
        XCTAssertEqual(
            SettingsPresentation.aboutProcessing(remoteProcessingActive: true, summaryDestination: .openRouter),
            "On device, or your server; summaries sent to OpenRouter"
        )
    }

    func testLocalFirstCardKeepsTheAudioClaimOnlyWhileItIsTrue() {
        let local = SettingsPresentation.localFirstDetail(remoteProcessingActive: false, summaryDestination: .none)
        XCTAssertTrue(local.contains("Voice recordings and downloaded speech models stay on this iPhone."), local)
        XCTAssertTrue(local.contains("private iCloud sync"), local)

        let remote = SettingsPresentation.localFirstDetail(remoteProcessingActive: true, summaryDestination: .none)
        XCTAssertFalse(remote.contains("recordings and downloaded speech models stay on this iPhone"), remote)
        XCTAssertTrue(remote.contains("recordings also go to your server"), remote)
    }

    func testLocalFirstCardNamesTheSummaryDestination() {
        func detail(_ destination: SettingsPresentation.SummaryDestination) -> String {
            SettingsPresentation.localFirstDetail(remoteProcessingActive: false, summaryDestination: destination)
        }
        XCTAssertFalse(detail(.none).contains("summaries"), detail(.none))
        XCTAssertTrue(detail(.yourServer).contains("your server for summaries"), detail(.yourServer))
        XCTAssertTrue(detail(.openRouter).contains("OpenRouter for summaries"), detail(.openRouter))
        XCTAssertTrue(detail(.chatGPT).contains("OpenAI through your ChatGPT account for summaries"), detail(.chatGPT))
    }

    func testRemoteProcessingActiveFollowsTheRealPolicy() {
        // The Settings strings read the same decision the recorder uses, not the stored switch.
        XCTAssertFalse(RemoteTranscriptionPolicy.isSettingActive(stored: true, endpointConfigured: true, summaryBackendIsCustomLLM: false))
        XCTAssertFalse(SettingsPresentation.isRemoteProcessingActive(stored: true, endpointConfigured: false, backend: .customLLM))
        XCTAssertFalse(SettingsPresentation.isRemoteProcessingActive(stored: true, endpointConfigured: true, backend: .openRouter))
        XCTAssertFalse(SettingsPresentation.isRemoteProcessingActive(stored: false, endpointConfigured: true, backend: .customLLM))
        XCTAssertTrue(SettingsPresentation.isRemoteProcessingActive(stored: true, endpointConfigured: true, backend: .customLLM))
    }

    // MARK: Reasons beside rows that cannot be used

    func testSummaryProviderReasonAppearsOnlyWhileSummariesAreOff() {
        XCTAssertEqual(
            SettingsPresentation.summaryProviderDisabledReason(summariesEnabled: false),
            "Turn on Meeting Summaries (under Meetings) to use these."
        )
        XCTAssertNil(SettingsPresentation.summaryProviderDisabledReason(summariesEnabled: true))
    }

    func testSyncNowReasonAppearsOnlyWhileSyncIsOff() {
        XCTAssertEqual(SettingsPresentation.syncNowDisabledReason(syncEnabled: false), "Turn on Sync with Mac first")
        XCTAssertNil(SettingsPresentation.syncNowDisabledReason(syncEnabled: true))
    }

    func testMeetingTemplateNote() {
        XCTAssertEqual(SettingsPresentation.meetingTemplateNote, "Used when summaries are on.")
    }

    func testTypingSwitchesSayTheKeyboardIgnoresThemWithoutFullAccess() throws {
        let autocorrect = try XCTUnwrap(SettingsPresentation.typingSwitchNote(.autocorrect, access: .missing))
        XCTAssertTrue(autocorrect.contains("Allow Full Access is off"), autocorrect)
        XCTAssertTrue(autocorrect.contains("ignores this switch"), autocorrect)
        XCTAssertTrue(autocorrect.contains("autocorrect stays on") || autocorrect.contains("keeps autocorrect on"), autocorrect)

        let live = try XCTUnwrap(SettingsPresentation.typingSwitchNote(.liveTyping, access: .missing))
        XCTAssertTrue(live.contains("ignores this switch"), live)
        XCTAssertTrue(live.contains("live typing"), live)

        for feature in [SettingsPresentation.TypingFeature.autocorrect, .liveTyping] {
            XCTAssertNil(SettingsPresentation.typingSwitchNote(feature, access: .granted))
            XCTAssertNil(SettingsPresentation.typingSwitchNote(feature, access: .unknown))
        }
    }

    // MARK: Keyboard status keeps its wording and yields the Full Access state

    func testKeyboardSetupStatusKeepsItsLabelsAndFullAccessState() {
        func status(open: Bool, enabled: Bool, fullAccess: Bool) -> KeyboardSetupStatus {
            KeyboardSetupStatus.resolve(hasOpenAccess: open, enabledConfirmed: enabled, fullAccessConfirmed: fullAccess)
        }
        XCTAssertEqual(status(open: true, enabled: false, fullAccess: false).label, "Enabled")
        XCTAssertEqual(status(open: true, enabled: false, fullAccess: false).fullAccess, .granted)
        XCTAssertEqual(status(open: false, enabled: true, fullAccess: true).label, "Needs first use")
        XCTAssertEqual(status(open: false, enabled: true, fullAccess: true).fullAccess, .granted)
        XCTAssertEqual(status(open: false, enabled: true, fullAccess: false).label, "Full Access needed")
        XCTAssertEqual(status(open: false, enabled: true, fullAccess: false).fullAccess, .missing)
        XCTAssertEqual(status(open: false, enabled: false, fullAccess: false).label, "Not confirmed")
        XCTAssertEqual(status(open: false, enabled: false, fullAccess: false).fullAccess, .unknown)
        XCTAssertEqual(KeyboardSetupStatus.unknown.label, "Unknown")
        XCTAssertEqual(KeyboardSetupStatus.unknown.fullAccess, .unknown)
    }

    // MARK: Renamed rows

    func testRenamedRowsKeepTheirPreferenceKeys() {
        // Labels changed; stored keys must not.
        XCTAssertEqual(MuesliPreferences.keyboardLiveTypingKey, "muesli.keyboard.liveTyping")
        XCTAssertEqual(MuesliPreferences.liveActivitiesForDictationsKey, "muesli.liveActivities.dictations")
        XCTAssertEqual(MuesliPreferences.keepDictationAudioRecordingsKey, "muesli.dictations.keepAudioRecordings")
        XCTAssertEqual(MuesliPreferences.longVoiceNoteModeEnabledKey, "muesli.dictations.longVoiceNoteMode.enabled")
    }

    func testRowAccessibilityLabelJoinsTitleAndDetail() {
        XCTAssertEqual(SettingsAccessibility.label(title: "Live typing", detail: "Words appear as you speak."), "Live typing. Words appear as you speak.")
        XCTAssertEqual(SettingsAccessibility.label(title: "Live typing", detail: ""), "Live typing")
        XCTAssertEqual(SettingsAccessibility.minimumTapTarget, 44)
    }
}
