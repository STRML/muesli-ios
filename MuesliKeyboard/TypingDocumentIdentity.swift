import Foundation

/// Reads `UITextDocumentProxy.documentIdentifier` without Swift's non-optional bridge.
///
/// UIKit declares the property as a non-null `NSUUID`, so Swift's getter bridges the result with an unconditional
/// cast and traps (EXC_BREAKPOINT) when the host has no document yet, which is the case early in a keyboard's
/// startup. Calling the same getter through the Objective-C runtime and casting conditionally turns that nil into
/// nil. Pass the proxy as an `AnyObject`; anything that does not answer the selector reads as nil.
enum TypingDocumentIdentity {
    static func read(from proxy: AnyObject) -> UUID? {
        let selector = NSSelectorFromString("documentIdentifier")
        guard proxy.responds(to: selector) else { return nil }
        let result: Unmanaged<AnyObject>? = proxy.perform(selector)
        return result?.takeUnretainedValue() as? UUID
    }
}
