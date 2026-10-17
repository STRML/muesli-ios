import Foundation
@testable import Muesli

/// A running app, for the keyboard tests that predate readiness. They write handoff states straight into the store
/// to stand in for the app, so the store is the app's: it stamps every write with one boot, and that boot has a
/// fresh heartbeat and a ready model. The keyboard then sees what it always saw: a live owner.
/// `KeyboardReadinessTests` is the place where the app is absent, stale or another boot.
enum LiveAppFixture {
    static let boot = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    static func store(directory: URL, bus: any CrossProcessEventPosting) -> SharedStore {
        let store = SharedStore(containerURL: directory, eventPoster: bus, bootID: boot)
        publish(to: store)
        return store
    }

    static func publish(
        to store: SharedStore,
        model: ReadinessModelState = .ready,
        mic: ReadinessMicState = .ready,
        at date: Date = Date()
    ) {
        let identity = AppBootIdentity(id: boot, startedAt: date.addingTimeInterval(-60), stamp: .current)
        try? store.saveAppReadiness(
            AppReadinessRecord(boot: identity, heartbeatAt: date, model: model, mic: mic),
            notify: false
        )
    }
}
