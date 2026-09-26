import Foundation
import AppKit

struct TextRegion: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct MemoryFrame: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var timestamp: Date
    var appName: String
    var bundleID: String
    var title: String
    var imagePath: String
    var meetingImagePath: String? = nil
    var text: String
    var regions: [TextRegion]
    var meetingRegions: [TextRegion] = []
    var sessionID: String? = nil
    var starred = false
    var deletedAt: Date? = nil
    var demo = false
    var sourceURL: String? = nil
    /// Changes whenever recording is interrupted or an excluded app becomes active.
    var continuityID: String? = nil
    var indexingComplete: Bool? = nil
    var endTimestamp:Date? = nil
    var pixelDigest:String? = nil
    var ocrKey:String? = nil
    var ocrRegionIDs:[String]? = nil
    var ocrMeetingRegionIDs:[String]? = nil
    var compactRegionIDs:Data? = nil
    var compactMeetingRegionIDs:Data? = nil
    var visualTime:Double? = nil
    var visualWidth:Int? = nil
    var visualHeight:Int? = nil
    var timeLabel: String { timestamp.recallFormatted(date: .abbreviated, time: .shortened) }
}

struct RecordingSession: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var startedAt: Date
    var endedAt: Date?
    var videoPath: String
    var appName: String
    var hasAudio: Bool
    var systemAudioPath: String? = nil
    var microphoneAudioPath: String? = nil
    var systemAudioOffset: Double? = nil
    var microphoneAudioOffset: Double? = nil
    var storagePolicy: Int? = nil
    var videoOptimizationChecked: Bool? = nil
    var videoOptimizationVersion: Int? = nil
    var originalVideoBytes: Int64? = nil
    var archivedVideoBytes: Int64? = nil
    var supersededVideoPath: String? = nil
    var usesExternalAudio:Bool? = nil
    var audioSources:[String]? = nil
    var unifiedVisualArchive:Bool? = nil
    var visualArchiveReady:Bool? = nil
}

struct TranscriptLine: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var sessionID: String
    var timestamp: Date
    var speaker: String
    var text: String
}

struct ModelProfile: Codable, Equatable, Sendable {
    var provider = "Ollama"
    var baseURL = "http://127.0.0.1:11434/v1"
    var model = "qwen3:8b"
    var isLocal = true
    var isBuiltin: Bool {provider == "Built-in"}
    static let builtinChat = ModelProfile(provider:"Built-in",baseURL:"http://127.0.0.1/v1",model:"Qwen3 · 1.7B",isLocal:true)
    static let builtinSpeech = ModelProfile(provider:"Built-in",baseURL:"http://127.0.0.1/v1",model:"Whisper · Base",isLocal:true)
}

enum OverlayAppearance: String, Codable {
    case warmDay, deepNight
    var label: String { self == .warmDay ? "Light":"Dark" }
}

struct AppSettings: Codable {
    var appearance = OverlayAppearance.warmDay
    var glassArchiveEnabled = false
    var chat = ModelProfile.builtinChat
    var transcription = ModelProfile.builtinSpeech
    var transcriptionEnabled = false
    var systemAudio = false
    var microphone = false
    var captureInterval = 3.0
    var retentionDays = 30
    var excludedApps = ["com.1password.1password", "com.apple.keychainaccess"]
    var excludedNames = ["1Password", "Keychain Access"]
    var displayID: UInt32? = nil
    var onboardingComplete = false
    var launchFilmSeen = false
    var launchAtLogin = false
    var showDockIcon = false
    var shortcuts = ShortcutConfiguration()
    init() {}
    private enum CodingKeys: String, CodingKey { case appearance, glassArchiveEnabled, chat, transcription, transcriptionEnabled, systemAudio, microphone, captureInterval, retentionDays, excludedApps, excludedNames, displayID, onboardingComplete, launchFilmSeen, launchAtLogin, showDockIcon, shortcuts }
    init(from decoder:Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        appearance = try c.decodeIfPresent(OverlayAppearance.self,forKey:.appearance) ?? appearance
        glassArchiveEnabled = try c.decodeIfPresent(Bool.self,forKey:.glassArchiveEnabled) ?? glassArchiveEnabled
        chat = try c.decodeIfPresent(ModelProfile.self,forKey:.chat) ?? chat
        transcription = try c.decodeIfPresent(ModelProfile.self,forKey:.transcription) ?? transcription
        transcriptionEnabled = try c.decodeIfPresent(Bool.self,forKey:.transcriptionEnabled) ?? transcriptionEnabled
        systemAudio = try c.decodeIfPresent(Bool.self,forKey:.systemAudio) ?? systemAudio
        microphone = try c.decodeIfPresent(Bool.self,forKey:.microphone) ?? microphone
        captureInterval = try c.decodeIfPresent(Double.self,forKey:.captureInterval) ?? captureInterval
        retentionDays = try c.decodeIfPresent(Int.self,forKey:.retentionDays) ?? retentionDays
        excludedApps = try c.decodeIfPresent([String].self,forKey:.excludedApps) ?? excludedApps
        excludedNames = try c.decodeIfPresent([String].self,forKey:.excludedNames) ?? excludedNames
        displayID = try c.decodeIfPresent(UInt32.self,forKey:.displayID)
        onboardingComplete = try c.decodeIfPresent(Bool.self,forKey:.onboardingComplete) ?? onboardingComplete
        launchFilmSeen = try c.decodeIfPresent(Bool.self,forKey:.launchFilmSeen) ?? launchFilmSeen
        launchAtLogin = try c.decodeIfPresent(Bool.self,forKey:.launchAtLogin) ?? launchAtLogin
        showDockIcon = try c.decodeIfPresent(Bool.self,forKey:.showDockIcon) ?? showDockIcon
        shortcuts = try c.decodeIfPresent(ShortcutConfiguration.self,forKey:.shortcuts) ?? shortcuts
    }
}

struct ChatMessage: Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var sources: [MemoryFrame] = []
}

enum RewindError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum LinkDetector {
    private static let detector = try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue)
    static func links(in text: String) -> [URL] {
        guard text.contains(".") || text.contains(":") else { return [] }
        return (detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [])
            .compactMap(\.url).filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
    }
}
