import XCTest
@testable import Muesli

/// The keyboard's truthful state, driven the way the extension is: the app and the keyboard are two connections
/// to one store, and time is a clock the test moves. Every test names its row in the failure matrix
/// (docs/keyboard-readiness.md). The rule under test: listening, writing and ready appear only when a live app
/// confirms them.
@MainActor
final class KeyboardReadinessTests: XCTestCase {
    private var directory: URL!
    private var bus: StubEventBus!
    private var keyboardStore: SharedStore!
    private var controller: KeyboardController!
    private var clock = Date()
    private var inserted: [String] = []
    private let logged = Locked<[(event: String, detail: [String: String])]>([])

    private let liveBoot = UUID()
    private let oldBoot = UUID()
    private let stamp = ReadinessBuildStamp.current

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyboard-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bus = StubEventBus()
        keyboardStore = SharedStore(containerURL: directory, eventPoster: bus)
        clock = Date()
        controller = makeController()
        inserted = []
        logged.mutate { $0 = [] }
        KeyboardDiagnosticsLog.captureForTesting = { [logged] event, detail in
            logged.mutate { $0.append((event, detail)) }
        }
    }

    override func tearDown() async throws {
        KeyboardDiagnosticsLog.captureForTesting = nil
        controller = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func makeController() -> KeyboardController {
        let controller = KeyboardController(store: keyboardStore, eventBus: bus)
        controller.now = { [unowned self] in self.clock }
        controller.currentFullAccess = { true }
        controller.textInserter = { [weak self] in self?.inserted.append($0) }
        return controller
    }

    private func appStore(_ boot: UUID? = nil) -> SharedStore {
        SharedStore(containerURL: directory, eventPoster: bus, bootID: boot ?? liveBoot)
    }

    /// The app publishes its record. `age` is how long ago it last beat.
    private func publishApp(
        boot: UUID? = nil,
        model: ReadinessModelState = .ready,
        mic: ReadinessMicState = .ready,
        age: TimeInterval = 0,
        stamp override: ReadinessBuildStamp? = nil
    ) throws {
        let identity = AppBootIdentity(id: boot ?? liveBoot, startedAt: clock.addingTimeInterval(-600), stamp: override ?? stamp)
        let record = AppReadinessRecord(boot: identity, heartbeatAt: clock.addingTimeInterval(-age), model: model, mic: mic)
        try appStore(boot).saveAppReadiness(record, notify: false)
    }

    /// A request the app (boot `owner`) was working on, left in `phase`.
    @discardableResult
    private func persistRequest(owner: UUID?, phase: KeyboardHandoffPhase, age: TimeInterval = 1) throws -> UUID {
        let request = DictationRequest()
        let writer = owner.map(appStore) ?? keyboardStore!
        try writer.claimRequest(request)
        if phase != .startRequested {
            try writer.saveKeyboardHandoffState(KeyboardHandoffState(
                requestID: request.id, phase: phase, recoveryAction: phase == .recoveryRequested ? .stop : nil,
                updatedAt: clock.addingTimeInterval(-age)
            ))
        }
        return request.id
    }

    private func events(_ name: String) -> [[String: String]] {
        logged.value.filter { $0.event == name }.map(\.detail)
    }

    // MARK: Fresh install and the first open after an update

    // R01
    func testAFreshInstallNeedsTheAppAndOpensItWithAPrepareTrip() throws {
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .needsApp(.neverOpened))
        XCTAssertEqual(controller.recordKeyMode, .openMuesli)
        let url = try XCTUnwrap(controller.effectiveLaunchURL)
        XCTAssertEqual(url.host, MuesliAppConstants.prepareHost)
        controller.primaryLaunchAction()
        XCTAssertNil(try keyboardStore.pendingRequest(), "a start request would hang")
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().phase, .idle)
        XCTAssertEqual(controller.statusText, "Opening Muesli")
        XCTAssertFalse(controller.showsActiveWaveform)
    }

    // R02a, R02b, R02c: a request an old boot left in progress is never shown as listening or writing, and it is
    // recorded once as terminal.
    func testAnOldBootsInProgressRequestIsIdleAndEndedOnce() throws {
        for phase in [KeyboardHandoffPhase.startAcknowledged, .recordingStarted, .stopRequested, .stopAcknowledged, .audioSaved, .transcribingStarted] {
            let id = try persistRequest(owner: oldBoot, phase: phase)
            try publishApp(boot: liveBoot)
            logged.mutate { $0 = [] }
            controller = makeController()
            controller.prepareInitialPresentationState()

            XCTAssertEqual(controller.dictationPhase, .idle, "\(phase)")
            XCTAssertFalse(controller.showsActiveWaveform, "\(phase)")
            XCTAssertNil(controller.livePreview, "\(phase)")
            XCTAssertNotEqual(controller.statusText, "Listening", "\(phase)")
            XCTAssertNotEqual(controller.primaryButtonRole, .stop, "\(phase)")
            let row = try keyboardStore.keyboardHandoffState()
            XCTAssertEqual(row.requestID, id)
            XCTAssertEqual(row.phase, .failed, "\(phase)")
            XCTAssertEqual(row.endReason, "app_restarted", "\(phase)")

            // A second keyboard instance reading the same row neither re-ends it nor logs it again.
            let second = makeController()
            second.prepareInitialPresentationState()
            XCTAssertEqual(second.dictationPhase, .idle)
            XCTAssertEqual(events("request.abandoned").count, 1, "\(phase)")
            XCTAssertEqual(events("request.abandoned").first?["reason"], "app_restarted")
            XCTAssertEqual(events("request.abandoned").first?["phase"], phase.rawValue)
        }
    }

    // R02d: a result that was queued before the update is delivered, not abandoned and not lost.
    func testAnUndeliveredResultFromBeforeTheUpdateIsInserted() throws {
        let id = try persistRequest(owner: oldBoot, phase: .recordingStarted)
        try appStore(oldBoot).saveResult(.init(requestID: id, text: "Words from before", engineIdentifier: "test"))
        try appStore(oldBoot).saveKeyboardHandoffState(.init(requestID: id, phase: .resultReady, updatedAt: clock.addingTimeInterval(-3_600)))
        try publishApp()
        controller.prepareInitialPresentationState()
        XCTAssertEqual(inserted, ["Words from before"])
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().phase, .inserted)
        XCTAssertFalse(controller.showsActiveWaveform)
        XCTAssertTrue(events("request.abandoned").isEmpty)
    }

    // R02e-R02h: settled phases from an old boot change nothing and are never ended again.
    func testSettledPhasesFromAnOldBootStaySettled() throws {
        for phase in [KeyboardHandoffPhase.copyRequired, .cancelled, .failed, .inserted] {
            try persistRequest(owner: oldBoot, phase: phase)
            try publishApp()
            controller = makeController()
            controller.prepareInitialPresentationState()
            XCTAssertNotEqual(controller.dictationPhase, .recording, "\(phase)")
            XCTAssertFalse(controller.showsActiveWaveform, "\(phase)")
            XCTAssertEqual(try keyboardStore.keyboardHandoffState().phase, phase)
            XCTAssertNil(try keyboardStore.keyboardHandoffState().endReason)
        }
        XCTAssertTrue(events("request.abandoned").isEmpty)
    }

    // R23: a recreated keyboard re-reads the same settled row. It logs the observation once.
    func testHandoffObservedIsLoggedOncePerChangeAcrossKeyboardInstances() throws {
        try persistRequest(owner: oldBoot, phase: .cancelled)
        try publishApp()
        for _ in 0..<5 {
            let keyboard = makeController()
            keyboard.prepareInitialPresentationState()
            keyboard.prepareInitialPresentationState()
        }
        XCTAssertEqual(events("handoff.observed").count, 1)
    }

    // R02: after the update the old state is gone; the first tap prepares, and a record from the new build with
    // a loaded model reports ready immediately.
    func testAnUpdatedAppNeedsAPrepareTripUntilTheNewBootReportsReady() throws {
        try publishApp(boot: oldBoot, model: .ready, age: 3_600, stamp: ReadinessBuildStamp(appVersion: "0.0.1", appBuild: "1", osVersion: stamp.osVersion))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .needsApp(.appUpdated))
        XCTAssertEqual(controller.effectiveLaunchURL?.host, MuesliAppConstants.prepareHost)
        XCTAssertEqual(controller.readinessPresentation.caption, "Muesli was updated. Open it to continue")

        try publishApp(boot: liveBoot, model: .loading(since: clock.addingTimeInterval(-40), progress: nil))
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .loading(.preparing, progress: nil, elapsed: 40))
        XCTAssertEqual(controller.readinessPresentation.caption, "Loading speech model, 40 s")
        XCTAssertFalse(controller.showsActiveWaveform)

        try publishApp(boot: liveBoot, model: .ready)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .ready)
    }

    // R28: the extension is newer than the app that is still beating.
    func testAFreshHeartbeatFromAnotherBuildIsNotLive() throws {
        try publishApp(age: 1, stamp: ReadinessBuildStamp(appVersion: "0.0.1", appBuild: "1", osVersion: stamp.osVersion))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .needsApp(.appUpdated))
    }

    // MARK: The app was killed

    // R03: killed mid-recording, same build, model fine: idle now, one trip to start again (the old flow).
    func testAKilledAppMidRecordingIsIdleAndStartsWithTheUsualTrip() throws {
        let id = try persistRequest(owner: liveBoot, phase: .recordingStarted)
        try publishApp(age: 60)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertFalse(controller.showsActiveWaveform)
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().endReason, "owner_lost")
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().requestID, id)
        XCTAssertEqual(controller.readiness.state, .needsApp(.appNotRunning))
        XCTAssertEqual(controller.readiness.recordAction, .openAppToStart)
        XCTAssertEqual(controller.effectiveLaunchURL?.host, MuesliAppConstants.dictateHost)
    }

    // R03/R04: killed while writing. The words are not shown as being written, and a new dictation can begin.
    func testAKilledAppMidTranscriptionIsIdleAndFreesTheNextDictation() throws {
        try persistRequest(owner: liveBoot, phase: .transcribingStarted)
        try publishApp(age: 60)
        controller.prepareInitialPresentationState()
        XCTAssertFalse(controller.showsActiveWaveform)
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertNoThrow(try keyboardStore.claimRequest(.init()))
    }

    // R06/R07: just refreshed versus just expired, and a clock that jumps.
    func testTheHeartbeatBoundaryDecidesWhetherARecordingIsReal() throws {
        let id = try persistRequest(owner: liveBoot, phase: .recordingStarted)
        try publishApp(age: 14.9)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.readiness.state, .recording)

        clock = clock.addingTimeInterval(0.2)   // the heartbeat is now 15.1 s old
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().requestID, id)
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().endReason, "owner_lost")
    }

    func testAClockMovedBackwardsReadsTheHeartbeatAsStale() throws {
        try persistRequest(owner: liveBoot, phase: .recordingStarted)
        try publishApp(age: 0)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.dictationPhase, .recording)
        clock = clock.addingTimeInterval(-3_600)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.dictationPhase, .idle)
    }

    // R10: the keyboard asked and the app is still launching. Starting, not abandoned and not recording.
    func testAStartWaitingForAnAppLaunchIsStartingNotAbandoned() throws {
        let request = DictationRequest()
        try keyboardStore.claimRequest(request)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .starting)
        XCTAssertEqual(controller.dictationPhase, .requested)
        clock = clock.addingTimeInterval(5)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .starting)
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().phase, .startRequested)

        // The app comes up and adopts it.
        try appStore().saveKeyboardHandoffState(.init(requestID: request.id, phase: .startAcknowledged))
        try publishApp()
        controller.reevaluateReadiness()
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().ownerBootID, liveBoot)
        XCTAssertEqual(controller.dictationPhase, .requested)
    }

    // R03: no app ever came. Past the bound the request is released, so the next tap is not "finish the current
    // dictation".
    func testAStartNobodyTookIsReleasedPastTheBound() throws {
        try keyboardStore.claimRequest(.init())
        controller.prepareInitialPresentationState()
        clock = clock.addingTimeInterval(12)
        controller.reevaluateReadiness()
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().endReason, "owner_lost")
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertNoThrow(try keyboardStore.claimRequest(.init()))
    }

    // MARK: Every model state, and what Record does (R11, R13)

    func testRecordInPlaceOnlyWhenTheModelIsReadyAndTheMicIsHot() throws {
        try publishApp(model: .ready, mic: .ready)
        try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, phase: .idle, supportsBackgroundStart: true, updatedAt: clock))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.recordAction, .startInPlace)
        XCTAssertEqual(controller.recordKeyMode, .action)
        controller.primaryAction()
        XCTAssertNotNil(try keyboardStore.pendingRequest())
        XCTAssertEqual(try keyboardStore.pendingCommand()?.action, .start)
    }

    func testRecordOpensTheAppWithAPrepareTripWhenTheModelIsNotReady() throws {
        let models: [ReadinessModelState] = [
            .notDownloaded, .downloading(progress: 0.3), .loading(since: clock.addingTimeInterval(-900), progress: nil),
            .notLoaded, .failed(.loadFailed), .deferredByBackoff(until: clock.addingTimeInterval(60)),
        ]
        for model in models {
            try publishApp(model: model, mic: .ready)
            try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
                isActive: true, phase: .idle, supportsBackgroundStart: true, updatedAt: clock))
            controller = makeController()
            controller.prepareInitialPresentationState()
            XCTAssertEqual(controller.recordKeyMode, .openMuesli, "\(model)")
            XCTAssertEqual(controller.effectiveLaunchURL?.host, MuesliAppConstants.prepareHost, "\(model)")
            controller.primaryLaunchAction()
            XCTAssertNil(try keyboardStore.pendingRequest(), "\(model): no start request that would hang")
            XCTAssertNil(try keyboardStore.pendingCommand(), "\(model)")
            XCTAssertFalse(controller.showsActiveWaveform, "\(model)")
        }
    }

    // A hot mic with a ready model but no runtime start (mic cold) keeps the one-trip start.
    func testReadyWithAColdMicKeepsTheStartTrip() throws {
        try publishApp(model: .ready, mic: .off)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .ready)
        XCTAssertEqual(controller.effectiveLaunchURL?.host, MuesliAppConstants.dictateHost)
        controller.primaryLaunchAction()
        XCTAssertNotNil(try keyboardStore.pendingRequest(), "the usual start request")
    }

    func testReadyOnDemandAfterAMemoryWarningStillStarts() throws {
        try publishApp(model: .readyOnDemand, mic: .ready)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .ready)
    }

    // R16
    func testWithoutFullAccessTheStateIsTheSetupStateAndNeverFake() throws {
        let broken = SharedStore(appGroupIdentifier: "group.invalid.\(UUID().uuidString)", containerURL: nil, eventPoster: bus)
        let keyboard = KeyboardController(store: broken, eventBus: bus)
        keyboard.now = { self.clock }
        keyboard.currentFullAccess = { false }
        keyboard.prepareInitialPresentationState()
        XCTAssertEqual(keyboard.readiness.state, .needsApp(.fullAccessOff))
        XCTAssertEqual(keyboard.readinessPresentation.caption, "Turn on Full Access to dictate")
        XCTAssertFalse(keyboard.showsActiveWaveform)
    }

    // A store that cannot be read even with Full Access on is a different failure from the setting being off.
    func testATransientReadFailureWithFullAccessKeepsTheLastRecord() throws {
        try publishApp(model: .ready)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .ready)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .ready, "keeps what it knew until the heartbeat ages out")
        clock = clock.addingTimeInterval(20)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .needsApp(.appNotRunning))
    }

    // R30: the app was suspended mid-load. A frozen "Loading" would be a lie.
    func testALoadThatStoppedBeatingIsNeedsAppNotLoading() throws {
        try publishApp(model: .loading(since: clock.addingTimeInterval(-180), progress: 0.2), age: 1)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .loading(.preparing, progress: 0.2, elapsed: 180))
        XCTAssertTrue(controller.readiness.offersEscape)
        clock = clock.addingTimeInterval(30)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .needsApp(.loadInterrupted))
        XCTAssertEqual(controller.readinessPresentation.caption, "Open Muesli to finish loading")
    }

    // R20: checking is brief.
    func testCheckingBecomesNeedsAppAfterTheWindow() throws {
        try publishApp(age: 60)
        controller.startObservingSharedState()
        defer { controller.stopObservingSharedState() }
        XCTAssertEqual(controller.readiness.state, .checking)
        clock = clock.addingTimeInterval(AppLivenessPolicy.checkingWindow + 0.1)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .needsApp(.appNotRunning))
    }

    // R29: a keyboard that has just appeared asks a running app for a beat.
    func testAppearingProbesTheApp() {
        controller.startObservingSharedState()
        defer { controller.stopObservingSharedState() }
        XCTAssertTrue(bus.postedEvents.contains(.readinessProbe))
    }

    // MARK: Bounded states (R20)

    func testALiveAppThatNeverAcknowledgesIsStalledAfterTheBound() throws {
        let request = DictationRequest()
        try appStore().claimRequest(request)
        try publishApp()
        controller.prepareInitialPresentationState()
        XCTAssertFalse(controller.readiness.offersEscape)
        clock = clock.addingTimeInterval(11)
        try publishApp()
        controller.reevaluateReadiness()
        XCTAssertTrue(controller.readiness.offersEscape || controller.primaryButtonRole == .openMuesliRecovery)
    }

    func testALongTranscriptionStaysTranscribingAndOffersAnEscape() throws {
        let id = try persistRequest(owner: liveBoot, phase: .transcribingStarted, age: 130)
        try publishApp()
        try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, activeRequestID: id, phase: .transcribing, updatedAt: clock))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .transcribing)
        XCTAssertTrue(controller.readiness.offersEscape)
        XCTAssertTrue(controller.canCancelActiveDictation)
    }

    // MARK: Owner stamping through the keyboard (R22)

    func testStopFromTheKeyboardKeepsTheAppsOwnership() throws {
        let id = try persistRequest(owner: liveBoot, phase: .recordingStarted)
        try publishApp()
        controller.prepareInitialPresentationState()
        controller.primaryAction()
        let row = try keyboardStore.keyboardHandoffState()
        XCTAssertEqual(row.phase, .stopRequested)
        XCTAssertEqual(row.ownerBootID, liveBoot)
        XCTAssertEqual(row.requestID, id)
        XCTAssertEqual(controller.readiness.state, .recording)
    }

    // MARK: The state changes while the user is in the keyboard (R14)

    func testTheRecordKeyBecomesNormalWhenTheLoadFinishesWithoutAnotherTrip() throws {
        try publishApp(model: .loading(since: clock.addingTimeInterval(-10), progress: nil))
        try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, phase: .idle, supportsBackgroundStart: true, updatedAt: clock))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.recordKeyMode, .openMuesli)
        try publishApp(model: .ready, mic: .ready)
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .ready)
        XCTAssertEqual(controller.recordKeyMode, .action)
    }

    // MARK: The stuck picture from a real phone (R31)

    // A flat meter, an owner that still beats, a pill that did nothing, Cancel that did not stick.
    func testARecordingWithNoAudioIsALostConnectionWithAnEscapeThatAlwaysWorks() throws {
        let id = try persistRequest(owner: liveBoot, phase: .recordingStarted, age: 10)
        try publishApp(age: 1)
        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.readiness.state, .connectionLost)
        XCTAssertEqual(controller.readinessPresentation.caption, "Lost connection to Muesli. Tap to reconnect")
        XCTAssertFalse(controller.canStopFromStatusPill, "a stop that cannot reach anyone is not offered")
        XCTAssertEqual(controller.recordKeyMode, .openMuesli)
        XCTAssertEqual(controller.effectiveLaunchURL?.host, MuesliAppConstants.openHost)
        XCTAssertFalse(controller.isPrimaryButtonDisabled)
        XCTAssertTrue(controller.canCancelActiveDictation)

        controller.cancelActiveDictation()
        let row = try keyboardStore.keyboardHandoffState()
        XCTAssertEqual(row.requestID, id)
        XCTAssertEqual(row.phase, .cancelled)
        XCTAssertEqual(row.endReason, "owner_lost")
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertEqual(try keyboardStore.pendingCommand()?.action, .cancel, "an app that only looked quiet still stops")

        // The app wakes up and keeps going: it cannot bring the recording back.
        try appStore().saveKeyboardHandoffState(.init(requestID: id, phase: .transcribingStarted))
        try appStore().saveKeyboardHandoffState(.init(requestID: id, phase: .recordingStarted))
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().phase, .cancelled)
        for _ in 0..<3 {
            let reappeared = makeController()
            reappeared.prepareInitialPresentationState()
            XCTAssertEqual(reappeared.dictationPhase, .idle)
            XCTAssertFalse(reappeared.showsActiveWaveform)
        }
        XCTAssertEqual(events("request.abandoned").count, 1)
    }

    // The exact sequence from the log: a persisted recordingStarted for X, no live boot, a Cancel that nobody
    // acknowledged, and the keyboard coming back. It must show idle and stay idle.
    func testACancelNobodyAcknowledgedNeverResurrectsTheRecording() throws {
        let id = try persistRequest(owner: oldBoot, phase: .recordingStarted)
        try publishApp(boot: oldBoot, age: 60)
        try appStore(oldBoot).saveKeyboardHandoffState(.init(requestID: id, phase: .cancelRequested))
        try keyboardStore.saveCommand(.init(requestID: id, action: .cancel))
        for round in 0..<4 {
            try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
                isActive: true, activeRequestID: id, phase: .recording, inputLevel: 0.4, updatedAt: clock))
            let reappeared = makeController()
            reappeared.prepareInitialPresentationState()
            reappeared.reevaluateReadiness()
            XCTAssertEqual(reappeared.dictationPhase, .idle, "round \(round)")
            XCTAssertFalse(reappeared.showsActiveWaveform, "round \(round)")
            XCTAssertNotEqual(reappeared.primaryButtonRole, .stop, "round \(round)")
        }
        let row = try keyboardStore.keyboardHandoffState()
        XCTAssertTrue([.failed, .cancelled].contains(row.phase))
        XCTAssertNotNil(row.endReason)
    }

    // The review's concern: a healthy recording must never read as a lost connection. While it records the app
    // republishes the level at least every 0.75 s, so the keyboard sees a fresh status on every one-second tick.
    func testAHealthyRecordingStaysRecordingForAsLongAsLevelsKeepArriving() throws {
        let id = try persistRequest(owner: liveBoot, phase: .recordingStarted, age: 0)
        try publishApp()
        controller.prepareInitialPresentationState()
        for second in 1...30 {
            clock = clock.addingTimeInterval(1)
            try publishApp()
            try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
                isActive: true, activeRequestID: id, phase: .recording, inputLevel: 0.2, updatedAt: clock))
            controller.reevaluateReadiness()
            XCTAssertEqual(controller.readiness.state, .recording, "second \(second)")
            XCTAssertTrue(controller.canStopFromStatusPill, "second \(second)")
        }
        // The levels stop: 6 s later it is a lost connection, not before.
        for second in 1...5 {
            clock = clock.addingTimeInterval(1)
            try publishApp()
            controller.reevaluateReadiness()
            XCTAssertEqual(controller.readiness.state, .recording, "silent second \(second)")
        }
        clock = clock.addingTimeInterval(1.5)
        try publishApp()
        controller.reevaluateReadiness()
        XCTAssertEqual(controller.readiness.state, .connectionLost)
    }

    // A cancel with a live, confirming owner still goes through the app.
    func testACancelWithALiveOwnerStillWaitsForTheApp() throws {
        let id = try persistRequest(owner: liveBoot, phase: .recordingStarted)
        try publishApp()
        try keyboardStore.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, activeRequestID: id, phase: .recording, inputLevel: 0.4, updatedAt: clock))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.readiness.state, .recording)
        controller.cancelActiveDictation()
        XCTAssertEqual(try keyboardStore.keyboardHandoffState().phase, .cancelRequested)
        XCTAssertEqual(controller.statusText, "Cancelling")
    }

    // MARK: Logging (R23)

    func testReadinessIsLoggedOncePerChangeNotPerRefresh() throws {
        controller.startObservingSharedState()
        defer { controller.stopObservingSharedState() }
        for _ in 0..<5 { controller.reevaluateReadiness(); controller.prepareInitialPresentationState() }
        try publishApp(model: .loading(since: clock.addingTimeInterval(-1), progress: 0.1))
        for progress in stride(from: 0.1, through: 0.5, by: 0.1) {
            try publishApp(model: .loading(since: clock.addingTimeInterval(-1), progress: progress))
            controller.reevaluateReadiness()
        }
        try publishApp(model: .ready)
        controller.reevaluateReadiness()
        // A second keyboard instance in the same state adds nothing.
        let second = makeController()
        second.startObservingSharedState()
        defer { second.stopObservingSharedState() }
        second.reevaluateReadiness()

        let states = events("keyboard.readiness").compactMap { $0["readiness"] }
        XCTAssertEqual(states, ["needsApp.neverOpened", "loading.preparing", "ready"])
    }

    // MARK: Recovery and the pages (R18, R19)

    func testARecoveryPromptStillOpensTheAppToFinish() throws {
        let request = DictationRequest()
        try appStore(oldBoot).claimRequest(request)
        try appStore(oldBoot).saveKeyboardHandoffState(.init(requestID: request.id, phase: .recoveryRequested, recoveryAction: .stop))
        try publishApp(age: 60, stamp: stamp)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.primaryButtonRole, .openMuesliRecovery)
        XCTAssertEqual(controller.readiness.recordAction, .openAppToRecover)
        XCTAssertEqual(controller.recordKeyMode, .openMuesli)
    }

    func testBothPagesReadTheSameState() throws {
        try publishApp(model: .loading(since: clock.addingTimeInterval(-40), progress: nil))
        controller.prepareInitialPresentationState()
        controller.selectedSurface = .type
        let typePage = controller.readinessPresentation
        controller.selectedSurface = .dictate
        XCTAssertEqual(controller.readinessPresentation, typePage)
        XCTAssertTrue(typePage.needsAttention)
    }
}
