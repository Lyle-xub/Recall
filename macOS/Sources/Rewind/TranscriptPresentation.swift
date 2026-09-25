import Foundation

/// Audio input tracks are not speaker identities. Keep the raw transcript in
/// storage; suppress only strong, nearby cross-track echoes in the reading view.
enum TranscriptPresentation {
    static let trackLabels: Set<String> = ["Meeting", "You", "Audio"]
    static func lines(_ source: [TranscriptLine]) -> [TranscriptLine] {
        let ordered = source.sorted { $0.timestamp < $1.timestamp }
        let system = ordered.filter { $0.speaker == "Meeting" }
        guard !system.isEmpty else { return ordered.filter { !isSilence($0.text) } }
        let indexed = system.map { ($0, tokens($0.text)) }
        var lower = 0
        return ordered.filter { line in
            guard !isSilence(line.text) else { return false }
            guard line.speaker == "You" else { return true }
            let words = tokens(line.text)
            // A brief response such as “yes” is not evidence of microphone echo.
            guard words.count >= 5, words.count <= 240 else { return true }
            let from = line.timestamp.addingTimeInterval(-18), to = line.timestamp.addingTimeInterval(18)
            while lower < indexed.count && indexed[lower].0.timestamp < from { lower += 1 }
            var nearby: [String] = [], cursor = lower
            while cursor < indexed.count && indexed[cursor].0.timestamp <= to {
                if indexed[cursor].0.sessionID == line.sessionID { nearby += indexed[cursor].1 }
                cursor += 1
                if nearby.count > 480 { break }
            }
            return !isEcho(words, in: nearby)
        }
    }
    static func usesTwoSides(_ lines: [TranscriptLine]) -> Bool {
        let speakers = Set(lines.map(\.speaker))
        return speakers.count > 1 && speakers.isDisjoint(with: trackLabels)
    }
    static func sourceLabel(_ speaker: String) -> String {
        switch speaker { case "You": return "Microphone"; case "Meeting": return "System audio"; case "Audio": return "Audio"; default: return speaker }
    }
    private static func isSilence(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value.isEmpty || ["[BLANK_AUDIO]", "[SILENCE]", "[NO_SPEECH]"].contains(value)
    }
    static func tokens(_ text: String) -> [String] {
        let value = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var tokens: [String] = [], word = ""
        for scalar in value.unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) { word.unicodeScalars.append(scalar) }
            else if !word.isEmpty { tokens.append(word); word = "" }
        }
        if !word.isEmpty { tokens.append(word) }; return tokens
    }
    private static func isEcho(_ words: [String], in nearby: [String]) -> Bool {
        guard nearby.count >= 5 else { return false }
        // Sentence splitting and punctuation may differ; the words must agree.
        // Approximate matching can erase a real correction (six vs ten days).
        guard nearby.count >= words.count else { return false }
        return (0...(nearby.count-words.count)).contains { start in
            nearby[start..<(start+words.count)].elementsEqual(words)
        }
    }
}

struct TranscriptPage: Sendable {
    let original: [TranscriptLine]
    let lines: [TranscriptLine]
    init(_ source: [TranscriptLine]) { original = source; lines = TranscriptPresentation.lines(source) }
}

struct RecognitionProgress: Equatable, Sendable {
    var pending = 0
    var active = false
}

/// Reserves the entire operation, including asynchronous preparation. Checking
/// a Process only after awaiting conversion allowed concurrent Whisper engines.
actor SpeechOperationGate {
    private var busy = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
        // The caller always releases an acquired lease, including cancellation.
    }
    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(throwing: CancellationError()) }
    }
}
