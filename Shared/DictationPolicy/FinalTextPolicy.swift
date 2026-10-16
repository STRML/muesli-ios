import Foundation

/// Picks the one text a finished dictation inserts when the streaming preview and the full-clip pass both ran.
///
/// The streaming text is only ever a preview and a fallback. The full-clip pass (on-device beside the remote
/// endpoint, inside its own budget) is what gets inserted when it succeeds, so the user never loses words when it
/// fails, times out or comes back empty.
enum FinalTextPolicy {
    /// What the full-clip pass returned. `nil` from the pass means it did not complete (the no-progress watchdog
    /// fired).
    struct FinalPass: Sendable, Equatable {
        let text: String
        let isRemote: Bool
    }

    enum Source: Sendable, Equatable {
        case finalPass(isRemote: Bool)
        case streaming
    }

    struct Decision: Sendable, Equatable {
        let text: String
        let source: Source
    }

    static func resolve(
        streamingText: String,
        isLongForm: Bool,
        timeoutError: @autoclosure () -> any Error,
        isolation: isolated (any Actor)? = #isolation,
        finalPass: () async throws -> FinalPass?
    ) async throws -> Decision {
        let streaming = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A long voice note keeps its streaming text, as before: a second pass over minutes of audio is not free.
        if isLongForm, !streaming.isEmpty {
            return Decision(text: streaming, source: .streaming)
        }
        // Nothing to fall back to: the final pass is the only pass, and its failures fail the dictation as before.
        guard !streaming.isEmpty else {
            guard let pass = try await finalPass() else { throw timeoutError() }
            return Decision(text: pass.text, source: .finalPass(isRemote: pass.isRemote))
        }

        let pass: FinalPass?
        do {
            pass = try await finalPass()
        } catch is CancellationError {
            // A cancel never turns into an insert of the streaming text.
            throw CancellationError()
        } catch {
            pass = nil
        }
        guard let pass, !pass.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Decision(text: streaming, source: .streaming)
        }
        return Decision(text: pass.text, source: .finalPass(isRemote: pass.isRemote))
    }
}
