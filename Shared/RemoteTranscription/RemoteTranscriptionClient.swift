import Foundation

enum RemoteTranscriptionError: Error, Equatable {
    case fileTooLarge
    case unreadableAudio
    case httpStatus(Int)
    case unusableResponse
    case transport(Int)

    /// What goes in the log. Never the URL, the key, or the audio.
    var logCategory: String {
        switch self {
        case .fileTooLarge: "recording over the size limit"
        case .unreadableAudio: "recording unreadable"
        case .httpStatus(let status): "server status \(status)"
        case .unusableResponse: "unusable response"
        case .transport(let code): "transport error \(code)"
        }
    }
}

/// OpenAI-compatible `POST .../audio/transcriptions`, sent to the user's own Custom LLM endpoint only.
struct RemoteTranscriptionClient: Sendable {
    let endpoint: URL
    let apiKey: String
    let model: String
    let session: URLSession

    init(endpoint: URL, apiKey: String, model: String = RemoteTranscriptionPolicy.asrModel, session: URLSession) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// One session for the probe and the upload, so the warmed connection is reused, and one that never follows a
    /// redirect: a 307 would re-send the recording to whatever host it names.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    /// Asks the transcription route a question without sending a recording, and times the answer.
    /// Gives up at `timeout`; the abandoned request is cancelled.
    func probe(timeout: TimeInterval) async -> RemoteProbeOutcome {
        await withTaskGroup(of: RemoteProbeOutcome.self) { group in
            group.addTask { await probeOnce() }
            group.addTask {
                _ = try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            let first = await group.next() ?? .unreachable
            group.cancelAll()
            return first
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        let audio = try readAudio(at: audioURL)
        var body = MultipartForm()
        body.addField("model", model)
        body.addField("language", "en")
        body.addField("response_format", "json")
        body.addFile("file", filename: Self.filename(for: audioURL), contentType: Self.contentType(for: audioURL), data: audio)
        let request = makeRequest(contentType: body.contentType)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: body.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw RemoteTranscriptionError.transport(error.code.rawValue)
        } catch {
            throw RemoteTranscriptionError.transport(0)
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteTranscriptionError.unusableResponse }
        guard (200..<300).contains(http.statusCode) else { throw RemoteTranscriptionError.httpStatus(http.statusCode) }
        return try Self.parseText(from: data)
    }

    // MARK: Internals

    private func probeOnce() async -> RemoteProbeOutcome {
        var body = MultipartForm()
        body.addField("model", model)
        body.addField("response_format", "json")
        var request = makeRequest(contentType: body.contentType)
        request.httpBody = body.data
        let start = ContinuousClock.now
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            let elapsed = ContinuousClock.now - start
            let latency = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return .classify(statusCode: http.statusCode, latency: latency)
        } catch {
            return .unreachable
        }
    }

    private func makeRequest(contentType: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // Cellular and Low Data Mode do not stop the probe; the upload only follows a probe that passed.
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        return request
    }

    private func readAudio(at url: URL) throws -> Data {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber else {
            throw RemoteTranscriptionError.unreadableAudio
        }
        guard size.intValue <= RemoteTranscriptionPolicy.maxUploadBytes else { throw RemoteTranscriptionError.fileTooLarge }
        guard let data = try? Data(contentsOf: url) else { throw RemoteTranscriptionError.unreadableAudio }
        return data
    }

    static func parseText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["text"] as? String,
              let text = RemoteTranscriptText.clean(raw)
        else { throw RemoteTranscriptionError.unusableResponse }
        return text
    }

    private static func filename(for url: URL) -> String {
        let ext = url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return ext.isEmpty ? "audio" : "audio.\(ext)"
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "wav": "audio/wav"
        case "caf": "audio/x-caf"
        case "mp3": "audio/mpeg"
        default: "application/octet-stream"
        }
    }
}

private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct MultipartForm {
    private let boundary = "muesli-\(UUID().uuidString)"
    private var parts = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    var data: Data { parts + Data("--\(boundary)--\r\n".utf8) }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data file: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        parts.append(file)
        append("\r\n")
    }

    private mutating func append(_ text: String) { parts.append(Data(text.utf8)) }
}
