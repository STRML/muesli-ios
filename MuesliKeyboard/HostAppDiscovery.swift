import ObjectiveC
import UIKit

/// Spike: finds the bundle id of the app the keyboard is typing into.
///
/// iOS has no public API for this. `UIInputViewController` exposes no host identity, and the keyboard's
/// `extensionContext` does not either. The candidates below read private state of the controller (or its
/// parent) and are therefore an App Store review risk (guideline 2.5.1: non-public APIs). They never use
/// key-value coding on a guess: an unknown key raises an Objective-C exception that Swift cannot catch and would
/// kill the keyboard, so each candidate is checked against the runtime (getter or ivar) before it is read.
///
/// Every attempt is written to `KeyboardDiagnosticsLog` as `host_probe` with what came back.
@MainActor
enum HostAppDiscovery {
    /// Private names tried, in order. Each is logged whether or not it exists on this iOS version.
    static let candidateNames = ["_hostBundleID", "hostBundleID", "_hostApplicationBundleIdentifier", "hostApplicationBundleIdentifier"]

    static func discover(from controller: UIInputViewController, logProbe: Bool = true) -> String? {
        var targets: [(label: String, object: NSObject)] = [("self", controller)]
        if let parent = controller.parent { targets.append(("parent", parent)) }
        for (label, object) in targets {
            for name in candidateNames {
                let outcome = read(name, from: object)
                if logProbe {
                    KeyboardDiagnosticsLog.record("host_probe", [
                        "target": label,
                        "class": String(describing: type(of: object)),
                        "key": name,
                        "found": String(outcome.found),
                        "value": outcome.value ?? "nil"
                    ])
                }
                if let valid = HostAppReturn.sanitized(outcome.value) { return valid }
            }
        }
        return nil
    }

    /// Reads a string-valued getter or ivar without raising: nothing is read unless the runtime reports it exists.
    static func read(_ name: String, from object: NSObject) -> (found: Bool, value: String?) {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let result = object.perform(selector) {
            return (true, result.takeUnretainedValue() as? String)
        }
        var cls: AnyClass? = type(of: object)
        while let current = cls {
            if let ivar = class_getInstanceVariable(current, name) {
                let encoding = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? ""
                guard encoding.hasPrefix("@") else { return (true, nil) }
                return (true, object_getIvar(object, ivar) as? String)
            }
            cls = class_getSuperclass(current)
        }
        return (false, nil)
    }

    #if DEBUG
    /// Logs runtime members whose names mention host/bundle/client, to find out what this iOS version really has.
    static func dumpRelatedMembers(of object: NSObject, label: String) {
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self {
            var names: [String] = []
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                for index in 0..<Int(count) {
                    if let cName = ivar_getName(ivars[index]) { names.append("ivar:" + String(cString: cName)) }
                }
                free(ivars)
            }
            if let methods = class_copyMethodList(current, &count) {
                for index in 0..<Int(count) {
                    names.append("sel:" + NSStringFromSelector(method_getName(methods[index])))
                }
                free(methods)
            }
            let related = names.filter { name in
                let lower = name.lowercased()
                return lower.contains("host") || lower.contains("bundle") || lower.contains("clientid")
            }
            KeyboardDiagnosticsLog.record("host_probe_members", [
                "target": label,
                "class": NSStringFromClass(current),
                "related": related.joined(separator: ",")
            ])
            cls = class_getSuperclass(current)
        }
    }
    #endif
}
