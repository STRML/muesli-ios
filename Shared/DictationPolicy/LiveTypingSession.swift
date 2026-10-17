import Foundation

/// What the keyboard can read from the host field around the cursor.
struct LiveTypingSnapshot: Equatable, Sendable {
    var before: String
    var after: String
    var selection: String
    var documentID: UUID?

    init(before: String = "", after: String = "", selection: String = "", documentID: UUID? = nil) {
        self.before = before
        self.after = after
        self.selection = selection
        self.documentID = documentID
    }
}

/// One thing the keyboard does to the host field.
enum LiveTypingCommand: Equatable, Sendable {
    /// `setMarkedText(text, selectedRange:)` with the cursor at the end of the text.
    case setMarked(String)
    /// `unmarkText()`: whatever is marked becomes plain text.
    case unmark
    /// `setMarkedText("")` then `unmarkText()`: removes the marked range and nothing else. Never a
    /// `deleteBackward`, which on a host that ignored the marked text would eat the user's own words.
    case clearMarked
    case deleteBackward(Int)
    case insert(String)
    case log(event: String, reason: String)
}

/// Why a dictation is not typing into the field, or stopped.
enum LiveTypingOff: String, Equatable, Sendable {
    case settingOff, noHost, selection, rewrite
    /// The user (or an older queued result) is about to edit the field.
    case yielded
    /// The keyboard is going away.
    case hidden
    /// The capability probe failed.
    case noChange, notAtCursor, appended
}

/// Why the words were left in the field as plain text.
enum LiveTypingKept: String, Equatable, Sendable {
    case cursorMoved, fieldChanged, textChanged
}

enum LiveTypingPhase: Equatable, Sendable {
    case awaitingFirstPartial
    /// The first words are marked; waiting to see them in the context.
    case probingAppearance
    /// The same words were marked again; waiting to see them replaced, not appended.
    case probingReplace
    case live
    case stripOnly(LiveTypingOff)
    case kept(LiveTypingKept)
    case cancelled
    case finished
}

struct LiveTypingFinal: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The words in the field are now the final text; nothing more to insert.
        case replacedInPlace
        /// Insert this text at the cursor, the way a dictation is inserted without live typing.
        case insertPlain(String)
        /// Leave the field as it is: the words are already there, and inserting again would duplicate them.
        case withheld(String)
    }

    var commands: [LiveTypingCommand]
    var outcome: Outcome
}

/// The state machine of one dictation's live typing. It decides; the keyboard performs the commands and tells it
/// what the field looks like afterwards.
///
/// The field holds `committed` (plain text this session put there, whole sentences of a long dictation) followed
/// by `marked` (the words that can still change), at the cursor.
struct LiveTypingSession: Sendable {
    let requestID: UUID
    private(set) var phase: LiveTypingPhase = .awaitingFirstPartial
    private(set) var committed = ""
    private(set) var marked = ""
    private var previousMarked = ""
    private let base: LiveTypingSnapshot
    private let chunkThreshold: Int
    /// What the field reported once the first words were marked; marking the same words again must not change it.
    private var afterFirstWrite = ""
    private var held: String?

    init(
        requestID: UUID,
        base: LiveTypingSnapshot,
        isEnabled: Bool,
        hasHost: Bool,
        isRewrite: Bool,
        chunkThreshold: Int = LiveTypingText.chunkThreshold
    ) {
        self.requestID = requestID
        self.base = base
        self.chunkThreshold = chunkThreshold
        if !isEnabled {
            phase = .stripOnly(.settingOff)
        } else if !hasHost {
            phase = .stripOnly(.noHost)
        } else if isRewrite {
            phase = .stripOnly(.rewrite)
        } else if !base.selection.isEmpty {
            // Marking would replace the selection, and Cancel could not put it back.
            phase = .stripOnly(.selection)
        }
    }

    var mirroredText: String { committed + marked }
    var isProbing: Bool { phase == .probingAppearance || phase == .probingReplace }
    var writesToHost: Bool { phase == .live || isProbing }

    // MARK: Streaming words

    mutating func partial(_ raw: String) -> [LiveTypingCommand] {
        let text = LiveTypingText.trimmedPartial(raw)
        guard !text.isEmpty else { return [] }
        switch phase {
        case .awaitingFirstPartial:
            marked = text
            phase = .probingAppearance
            return [.setMarked(text)]
        case .probingAppearance, .probingReplace:
            held = text
            return []
        case .live:
            return write(text)
        case .stripOnly, .kept, .cancelled, .finished:
            return []
        }
    }

    /// Replaces the whole marked range with the newest tail, or commits finished sentences of a long dictation.
    private mutating func write(_ text: String) -> [LiveTypingCommand] {
        guard text.hasPrefix(committed) else { return [] }
        let tail = String(text.dropFirst(committed.count))
        guard !tail.isEmpty, tail != marked else { return [] }
        if let split = LiveTypingText.sentenceSplit(tail, threshold: chunkThreshold) {
            committed += split.commit
            previousMarked = marked
            marked = split.rest
            return [.setMarked(split.commit), .unmark, .setMarked(split.rest)]
        }
        previousMarked = marked
        marked = tail
        return [.setMarked(tail)]
    }

    // MARK: What the field looks like afterwards

    /// The field reported a change (or the timeout fired, `forced`). `settled` is false right after a write, while
    /// the proxy may still be showing the previous text.
    mutating func observed(_ snapshot: LiveTypingSnapshot, forced: Bool, settled: Bool) -> [LiveTypingCommand] {
        switch phase {
        case .probingAppearance: return observeAppearance(snapshot, forced: forced)
        case .probingReplace: return observeReplacement(snapshot, forced: forced)
        case .live: return settled ? observeAttachment(snapshot) : []
        default: return []
        }
    }

    private func sameAfter(_ snapshot: LiveTypingSnapshot) -> Bool {
        LiveTypingText.folded(snapshot.after) == LiveTypingText.folded(base.after)
    }

    private func isAtCursor(_ snapshot: LiveTypingSnapshot) -> Bool {
        snapshot.documentID == base.documentID && sameAfter(snapshot) && snapshot.selection.isEmpty
    }

    private mutating func observeAppearance(_ snapshot: LiveTypingSnapshot, forced: Bool) -> [LiveTypingCommand] {
        if isAtCursor(snapshot), LiveTypingText.contextEnds(with: marked, in: snapshot.before),
           LiveTypingText.folded(snapshot.before) != LiveTypingText.folded(base.before) {
            afterFirstWrite = snapshot.before
            phase = .probingReplace
            previousMarked = marked
            return [.setMarked(marked)]
        }
        // Text that landed somewhere else is a definite failure; "nothing yet" may just be a slow proxy.
        if !sameAfter(snapshot) || snapshot.documentID != base.documentID { return unsupported(.notAtCursor) }
        return forced ? unsupported(.noChange) : []
    }

    private mutating func observeReplacement(_ snapshot: LiveTypingSnapshot, forced: Bool) -> [LiveTypingCommand] {
        let seen = LiveTypingText.folded(snapshot.before)
        let first = LiveTypingText.folded(afterFirstWrite)
        let doubled = LiveTypingText.folded(marked + marked)
        if isAtCursor(snapshot), seen == first {
            phase = .live
            guard let next = held else { return [] }
            held = nil
            return write(next)
        }
        // The host inserted the words as plain text again: the first copy is the only one that should remain.
        if seen.count > first.count, seen.hasPrefix(first), seen.hasSuffix(doubled) {
            phase = .stripOnly(.appended)
            return [.deleteBackward(marked.count * 2), .log(event: "live_typing.unsupported", reason: "appended")]
        }
        if !isAtCursor(snapshot) { return unsupported(.notAtCursor) }
        return forced ? unsupported(.noChange) : []
    }

    private mutating func unsupported(_ reason: LiveTypingOff) -> [LiveTypingCommand] {
        phase = .stripOnly(reason)
        marked = ""
        held = nil
        return [.clearMarked, .log(event: "live_typing.unsupported", reason: reason.rawValue)]
    }

    /// Whether the field still ends with the words this session typed, with the same text after the cursor. The
    /// proxy can lag one write behind, so the previous marked text counts too.
    private func isAttached(_ snapshot: LiveTypingSnapshot) -> Bool {
        guard isAtCursor(snapshot) else { return false }
        if LiveTypingText.contextEnds(with: marked, in: snapshot.before) { return true }
        return !previousMarked.isEmpty && LiveTypingText.contextEnds(with: previousMarked, in: snapshot.before)
    }

    private func detachReason(_ snapshot: LiveTypingSnapshot) -> LiveTypingKept {
        if snapshot.documentID != base.documentID { return .fieldChanged }
        if !snapshot.selection.isEmpty || !sameAfter(snapshot) { return .cursorMoved }
        return .textChanged
    }

    private mutating func observeAttachment(_ snapshot: LiveTypingSnapshot) -> [LiveTypingCommand] {
        guard !isAttached(snapshot) else { return [] }
        let reason = detachReason(snapshot)
        phase = .kept(reason)
        return [.unmark, .log(event: "live_typing.detached", reason: reason.rawValue)]
    }

    // MARK: Ending

    /// The user is about to edit the field (a key, a backspace, an older queued insert), or the keyboard is going
    /// away. The words come out and the final is inserted at the cursor as it is without live typing.
    mutating func yield(_ reason: LiveTypingOff) -> [LiveTypingCommand] {
        switch phase {
        case .awaitingFirstPartial:
            phase = .stripOnly(reason)
            return []
        case .probingAppearance, .probingReplace, .live:
            phase = .stripOnly(reason)
            marked = ""
            held = nil
            return [.clearMarked, .log(event: "live_typing.yielded", reason: reason.rawValue)]
        case .stripOnly, .kept, .cancelled, .finished:
            return []
        }
    }

    /// The user cancelled: the field goes back to how it was.
    mutating func cancel(snapshot: LiveTypingSnapshot) -> [LiveTypingCommand] {
        defer {
            phase = .cancelled
            marked = ""
            held = nil
        }
        switch phase {
        case .probingAppearance, .probingReplace, .live:
            var commands: [LiveTypingCommand] = [.clearMarked]
            commands += removeCommitted(snapshot: snapshot, withMarked: marked)
            return commands
        case .stripOnly:
            return removeCommitted(snapshot: snapshot, withMarked: "")
        case .awaitingFirstPartial, .kept, .cancelled, .finished:
            return []
        }
    }

    private func removeCommitted(snapshot: LiveTypingSnapshot, withMarked tail: String) -> [LiveTypingCommand] {
        let count = committed.count
        guard count > 0, count <= LiveTypingText.maxRewriteDelete,
              LiveTypingText.contextEnds(with: committed + tail, in: snapshot.before)
        else { return [] }
        return [.deleteBackward(count)]
    }

    /// The dictation ended with no text to insert (failed, or handed to the clipboard): keep the words.
    mutating func endWithoutResult() -> [LiveTypingCommand] {
        switch phase {
        case .probingAppearance, .probingReplace, .live:
            phase = .finished
            return [.unmark]
        default:
            return []
        }
    }

    // MARK: The final text

    mutating func final(_ text: String, snapshot: LiveTypingSnapshot) -> LiveTypingFinal {
        var leading: [LiveTypingCommand] = []
        if isProbing {
            // The probe is out of time: decide with what the field shows now.
            leading = observed(snapshot, forced: true, settled: true)
            if phase == .probingReplace { leading += observed(snapshot, forced: true, settled: true) }
        }
        let result = finish(text, snapshot: snapshot)
        return LiveTypingFinal(commands: leading + result.commands, outcome: result.outcome)
    }

    private mutating func finish(_ text: String, snapshot: LiveTypingSnapshot) -> LiveTypingFinal {
        switch phase {
        case .awaitingFirstPartial:
            phase = .finished
            return LiveTypingFinal(commands: [], outcome: .insertPlain(text))
        case .stripOnly:
            phase = .finished
            return finishPlain(text)
        case .kept:
            phase = .finished
            return LiveTypingFinal(commands: [], outcome: .withheld("detached"))
        case .cancelled:
            return LiveTypingFinal(commands: [], outcome: .withheld("cancelled"))
        case .finished:
            return LiveTypingFinal(commands: [], outcome: .withheld("finished"))
        case .live, .probingAppearance, .probingReplace:
            return finishLive(text, snapshot: snapshot)
        }
    }

    /// No live typing at the end: the text goes in at the cursor, minus whatever this session already committed.
    private func finishPlain(_ text: String) -> LiveTypingFinal {
        guard !committed.isEmpty else { return LiveTypingFinal(commands: [], outcome: .insertPlain(text)) }
        guard text.hasPrefix(committed) else {
            return LiveTypingFinal(commands: [], outcome: .withheld("committed"))
        }
        let rest = String(text.dropFirst(committed.count))
        return LiveTypingFinal(commands: [], outcome: rest.isEmpty ? .replacedInPlace : .insertPlain(rest))
    }

    private mutating func finishLive(_ text: String, snapshot: LiveTypingSnapshot) -> LiveTypingFinal {
        guard phase == .live else { return finish(text, snapshot: snapshot) }
        guard isAttached(snapshot) else {
            phase = .finished
            return LiveTypingFinal(
                commands: [.unmark, .log(event: "live_typing.detached", reason: detachReason(snapshot).rawValue)],
                outcome: .withheld("detached")
            )
        }
        defer { phase = .finished }
        if committed.isEmpty {
            let commands: [LiveTypingCommand] = text == marked ? [.unmark] : [.setMarked(text), .unmark]
            return LiveTypingFinal(commands: commands, outcome: .replacedInPlace)
        }
        if text.hasPrefix(committed) {
            let rest = String(text.dropFirst(committed.count))
            let commands: [LiveTypingCommand] = rest.isEmpty ? [.clearMarked] : [.setMarked(rest), .unmark]
            return LiveTypingFinal(commands: commands, outcome: .replacedInPlace)
        }
        // The final revised words that were already committed: delete them and type the final, if the field
        // still ends with exactly what this session put there. Not atomic, and the host sees each deletion.
        let count = mirroredText.count
        guard count <= LiveTypingText.maxRewriteDelete,
              LiveTypingText.contextEnds(with: mirroredText, in: snapshot.before)
        else {
            return LiveTypingFinal(commands: [.unmark], outcome: .withheld("rewrite"))
        }
        return LiveTypingFinal(commands: [.unmark, .deleteBackward(count), .insert(text)], outcome: .replacedInPlace)
    }
}
