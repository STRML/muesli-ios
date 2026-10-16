import Foundation

/// The URLSession for every Custom LLM request: summaries, Quill rewrites and the model list. It follows a
/// redirect only to the same scheme, host and port, so a redirect can never carry a transcript, typed text or
/// the API key to another server.
enum CustomLLMSession {
    static let shared = make()

    static func make(configuration: URLSessionConfiguration = .default) -> URLSession {
        URLSession(configuration: configuration, delegate: SameOriginRedirectGuard(), delegateQueue: nil)
    }

    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
              let fromScheme = original.scheme?.lowercased(), let toScheme = target.scheme?.lowercased(),
              let fromHost = original.host?.lowercased(), let toHost = target.host?.lowercased()
        else { return false }
        return fromScheme == toScheme
            && fromHost == toHost
            && effectivePort(original, scheme: fromScheme) == effectivePort(target, scheme: toScheme)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        url.port ?? ["https": 443, "http": 80][scheme]
    }
}

private final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = CustomLLMSession.allowsRedirect(from: task.originalRequest?.url, to: request.url)
        completionHandler(allowed ? request : nil)
    }
}
