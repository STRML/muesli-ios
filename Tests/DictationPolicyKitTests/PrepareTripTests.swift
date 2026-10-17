import XCTest
@testable import DictationPolicyKit

/// The app's side of the prepare trip: what the Preparing screen says, when it prompts the user back, and when a
/// local notification is worth posting. Rows R14 (the trip ends while the user is in the app versus already back
/// in the keyboard) and R26 (notifications).
final class PrepareTripTests: XCTestCase {
    private typealias F = ReadinessFixtures
    private let t0 = F.t0

    private func trip(host: String? = nil) -> PrepareTrip {
        PrepareTrip(id: UUID(), startedAt: t0, hostAppName: host)
    }

    func testATripBeginsWorking() {
        let trip = trip()
        XCTAssertEqual(trip.outcome, .working)
        XCTAssertFalse(trip.isFinished)
    }

    // R14: the user waits in the app. The screen turns to Ready, and no notification is posted.
    func testReadyWhileTheUserIsInTheAppPromptsWithoutANotification() {
        var trip = trip()
        XCTAssertNil(trip.apply(model: .loading(since: t0, progress: 0.5), now: t0.addingTimeInterval(30), isAppActive: true, notificationsAllowed: true))
        XCTAssertEqual(trip.outcome, .working)
        XCTAssertNil(trip.apply(model: .ready, now: t0.addingTimeInterval(60), isAppActive: true, notificationsAllowed: true))
        XCTAssertEqual(trip.outcome, .ready(at: t0.addingTimeInterval(60)))
        XCTAssertTrue(trip.isFinished)
    }

    // R14, R26: the user already went back to the keyboard. If notifications are allowed, the app taps them.
    func testReadyInTheBackgroundNotifiesOnceWhenAllowed() {
        var trip = trip()
        let effect = trip.apply(model: .ready, now: t0.addingTimeInterval(900), isAppActive: false, notificationsAllowed: true)
        XCTAssertEqual(effect, .notifyReady)
        XCTAssertTrue(trip.notified)
        XCTAssertNil(trip.apply(model: .ready, now: t0.addingTimeInterval(901), isAppActive: false, notificationsAllowed: true), "once")
    }

    func testReadyInTheBackgroundWithoutPermissionStaysSilent() {
        var trip = trip()
        XCTAssertNil(trip.apply(model: .ready, now: t0, isAppActive: false, notificationsAllowed: false))
        XCTAssertEqual(trip.outcome, .ready(at: t0))
        XCTAssertFalse(trip.notified)
    }

    func testReadyOnDemandCountsAsReady() {
        var trip = trip()
        _ = trip.apply(model: .readyOnDemand, now: t0, isAppActive: true, notificationsAllowed: false)
        XCTAssertEqual(trip.outcome, .ready(at: t0))
    }

    func testAFailedLoadEndsTheTripWithTheReason() {
        var trip = trip()
        XCTAssertNil(trip.apply(model: .failed(.loadFailed), now: t0, isAppActive: false, notificationsAllowed: true))
        XCTAssertEqual(trip.outcome, .failed(.loadFailed))
        XCTAssertTrue(trip.isFinished)
    }

    func testAMissingModelWaitsForTheUsersChoice() {
        var trip = trip()
        _ = trip.apply(model: .notDownloaded, now: t0, isAppActive: true, notificationsAllowed: false)
        XCTAssertEqual(trip.outcome, .needsDownload)
        XCTAssertFalse(trip.isFinished)
    }

    // A finished trip is not reopened by a later model change (say, a memory warning).
    func testAFinishedTripIsFinal() {
        var trip = trip()
        _ = trip.apply(model: .ready, now: t0, isAppActive: true, notificationsAllowed: false)
        _ = trip.apply(model: .loading(since: t0, progress: nil), now: t0.addingTimeInterval(5), isAppActive: true, notificationsAllowed: false)
        XCTAssertEqual(trip.outcome, .ready(at: t0))
    }

    func testDeferredAndUnloadedStatesKeepWorking() {
        for model in [ReadinessModelState.notLoaded, .deferredByBackoff(until: t0), .downloading(progress: 0.1)] {
            var trip = trip()
            _ = trip.apply(model: model, now: t0, isAppActive: true, notificationsAllowed: false)
            XCTAssertEqual(trip.outcome, .working, "\(model)")
        }
    }

    // MARK: What the Preparing screen says

    private func screen(_ trip: PrepareTrip, model: ReadinessModelState, now: TimeInterval = 0) -> PrepareTripPresentation {
        PrepareTripPresentation.make(trip: trip, model: model, now: t0.addingTimeInterval(now))
    }

    func testWhileLoadingItShowsElapsedTimeAndTheHonestNote() {
        let presentation = screen(trip(), model: .loading(since: t0, progress: nil), now: 40)
        XCTAssertEqual(presentation.title, "Getting Muesli ready")
        XCTAssertEqual(presentation.detail, "Loading the speech model, 40 s")
        XCTAssertEqual(presentation.note, "The first load after an update can take a few minutes. Keep Muesli open until it finishes.")
        XCTAssertTrue(presentation.showsProgress)
        XCTAssertNil(presentation.primaryButton)
    }

    func testWhileDownloadingItShowsTheProgress() {
        let presentation = screen(trip(), model: .downloading(progress: 0.42))
        XCTAssertEqual(presentation.title, "Downloading the speech model")
        XCTAssertEqual(presentation.detail, "42%")
        XCTAssertEqual(presentation.progress, 0.42)
    }

    func testReadyNamesTheHostWhenItIsKnown() {
        var trip = trip(host: "Notes")
        _ = trip.apply(model: .ready, now: t0, isAppActive: true, notificationsAllowed: false)
        let presentation = screen(trip, model: .ready)
        XCTAssertEqual(presentation.title, "Ready")
        XCTAssertEqual(presentation.detail, "Switch back to Notes")
        XCTAssertFalse(presentation.showsProgress)
    }

    func testReadyWithoutAHostSaysSwipeBack() {
        var trip = trip()
        _ = trip.apply(model: .ready, now: t0, isAppActive: true, notificationsAllowed: false)
        let presentation = screen(trip, model: .ready)
        XCTAssertEqual(presentation.detail, "Swipe back to your app")
        XCTAssertEqual(presentation.note, "Swipe right along the bottom edge of the screen, or tap the app name in the top corner.")
    }

    func testFailureOffersARetry() {
        var trip = trip()
        _ = trip.apply(model: .failed(.loadFailed), now: t0, isAppActive: true, notificationsAllowed: false)
        let presentation = screen(trip, model: .failed(.loadFailed))
        XCTAssertEqual(presentation.title, "Couldn't load the speech model")
        XCTAssertEqual(presentation.primaryButton, .retry)
    }

    func testAMissingModelOffersTheDownload() {
        var trip = trip()
        _ = trip.apply(model: .notDownloaded, now: t0, isAppActive: true, notificationsAllowed: false)
        let presentation = screen(trip, model: .notDownloaded)
        XCTAssertEqual(presentation.primaryButton, .download)
    }
}
