import Foundation
import Combine

enum MediaRecognitionState: Codable, Equatable, Sendable {
    case checking, queued, processing, complete, empty, noAudio, disabled, notProcessed, awaitingEnd
    case failed(String)
    var isFailure:Bool { if case .failed = self { return true }; return false }
}

enum RecognitionJob:Hashable { case image(String), recording(String) }

/// Per-item activity does not invalidate the whole detail/timeline layout.
@MainActor final class RecognitionActivity:ObservableObject {
    @Published private(set) var jobs:[RecognitionJob:MediaRecognitionState] = [:]
    private var recentResults:[RecognitionJob] = []
    subscript(_ job:RecognitionJob)->MediaRecognitionState? { jobs[job] }
    func set(_ state:MediaRecognitionState?,for job:RecognitionJob) {
        guard jobs[job] != state else { return }
        jobs[job] = state
        // Persisted results bridge asynchronous selection reads. Bound the
        // cache without evicting pending or active recognition operations.
        recentResults.removeAll { $0 == job }
        if case .recording = job, let state, state != .queued && state != .processing {
            recentResults.append(job)
            while recentResults.count > 128 { jobs.removeValue(forKey:recentResults.removeFirst()) }
        }
    }
}

struct RecordingRecognitionDetail:Sendable {
    let sessionID:String
    let session:RecordingSession?
    let transcript:TranscriptPage
    let outcome:MediaRecognitionState?
    static func load(_ id:String,store:MemoryStore)throws->Self {
        Self(sessionID:id,session:try store.session(id),transcript:TranscriptPage(try store.transcript(id)),outcome:try store.recognitionOutcome(id))
    }
    func state(enabled:Bool)->MediaRecognitionState {
        if let outcome { return outcome }
        if !transcript.lines.isEmpty { return .complete }
        // Legacy recordings have no completion marker: an empty queue is not
        // evidence that a silent recording was successfully processed.
        guard let session else { return .notProcessed }
        guard session.hasAudio || session.systemAudioPath != nil || session.microphoneAudioPath != nil else { return .noAudio }
        if session.endedAt == nil { return .awaitingEnd }
        return enabled ? .notProcessed:.disabled
    }
}

struct RecognitionStatusSnapshot:Equatable {
    var contextID:String
    var text:MediaRecognitionState?
    var speech:MediaRecognitionState?
    var hasIssue:Bool { text?.isFailure == true || speech?.isFailure == true }

    @MainActor static func current(frame:MemoryFrame,video:Bool,meeting:Bool,activity:RecognitionActivity,recording:RecordingRecognitionDetail?,speechEnabled:Bool)->Self {
        let surface = video ? "video":meeting && frame.meetingImagePath != nil ? "meeting":"image"
        let text:MediaRecognitionState?
        if video { text = nil } // Archived video is never OCR'd.
        else if surface == "meeting" { text = frame.meetingRegions.isEmpty ? .empty:.complete }
        else if frame.indexingComplete == true { text = frame.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? .empty:.complete }
        else if let job = activity[.image(frame.id)] { text = job }
        else if frame.indexingComplete == false { text = frame.deletedAt == nil ? .queued:.notProcessed }
        else { text = frame.text.isEmpty && frame.regions.isEmpty ? .notProcessed:.complete }
        var speech:MediaRecognitionState?
        if let id = frame.sessionID {
            if let job = activity[.recording(id)] { speech = job }
            else if let recording,recording.sessionID == id { speech = recording.state(enabled:speechEnabled) }
            else { speech = .checking }
        }
        return Self(contextID:frame.id+":"+surface,text:text,speech:speech)
    }
}
