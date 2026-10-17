import CryptoKit
import Foundation

/// A short hash of the API key, enough to notice that it changed without keeping the key.
enum DiagnosticsKeyFingerprint {
    static func of(_ key: String) -> String {
        SHA256.hash(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// `POST` to the exact address a batch was gathered for, with the bearer key and the batch id as `Idempotency-Key`.
///
/// The session is injected. The app passes the remote-transcription session, which refuses redirects: a 307 would
/// otherwise carry the key and the batch to whatever host it names (and the engine reads the unfollowed 3xx as a
/// stop). Before sending, the transport re-checks that the key still matches the one the pass started with, and that
/// the address is https, so settings that changed mid-pass can never send an old queue somewhere new.
struct DiagnosticsURLSessionTransport: DiagnosticsTransport {
    let session: URLSession
    let currentKey: @Sendable () -> String

    func send(body: Data, batchID: String, target: DiagnosticsTargetRecord) async -> DiagnosticsTransportResult {
        guard let url = URL(string: target.endpoint), url.scheme == "https" else { return .cancelled }
        let key = currentKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiagnosticsKeyFingerprint.of(key) == target.keyFingerprint else { return .cancelled }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(batchID, forHTTPHeaderField: "Idempotency-Key")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (_, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else { return .networkFailure(code: 0) }
            if [429, 503].contains(http.statusCode),
               let header = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
                return .deferred(status: http.statusCode, retryAfter: seconds)
            }
            return .status(http.statusCode)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError {
            return error.code == .cancelled ? .cancelled : .networkFailure(code: error.code.rawValue)
        } catch {
            return .networkFailure(code: 0)
        }
    }
}
