import Foundation

extension ReadinessBuildStamp {
    /// The build this process is: the app and its keyboard extension ship together, so both read the same version
    /// and build, and the OS is the one both run on.
    static var current: ReadinessBuildStamp {
        let info = Bundle.main.infoDictionary
        return ReadinessBuildStamp(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: info?["CFBundleVersion"] as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

extension AppBootIdentity {
    /// A new boot: the id changes every time the app process starts.
    static func startNow(stamp: ReadinessBuildStamp = .current, at date: Date = .now) -> AppBootIdentity {
        AppBootIdentity(id: UUID(), startedAt: date, stamp: stamp)
    }
}
