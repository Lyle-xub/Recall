import Foundation

enum AppUsageKind: String, Codable, Sendable { case application, recall, excluded, unavailable }

struct AppUsageIdentity: Codable, Equatable, Sendable {
    let name: String
    let bundleID: String
    var kind: AppUsageKind = .application

    static func resolved(name: String, bundleID: String, ownApp: Bool, settings: AppSettings) -> Self {
        if settings.excludedApps.contains(bundleID) || settings.excludedNames.contains(name) {
            return Self(name:"Private activity",bundleID:"",kind:.excluded)
        }
        return Self(name:ownApp ? "Recall":name,bundleID:bundleID,kind:ownApp ? .recall:.application)
    }
    static let unavailable = Self(name:"Screen unavailable",bundleID:"",kind:.unavailable)
}

/// Application usage is independent of screenshot/OCR delivery. Every switch
/// closes the previous interval at exactly the next interval's starting time.
struct AppUsageInterval: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    let app: AppUsageIdentity
    let start: Date
    var end: Date
}

@MainActor final class AppUsageRecorder {
    private let store: MemoryStore
    private let backgroundWrites:Bool
    private var pendingWrite:Task<Void,Never>?
    var onError:((Error)->Void)?
    private(set) var current: AppUsageInterval?
    var onChange: (() -> Void)?
    init(store:MemoryStore,backgroundWrites:Bool = false) { self.store = store;self.backgroundWrites = backgroundWrites }
    private func save(_ interval:AppUsageInterval) throws {
        guard backgroundWrites else { try store.saveUsage(interval);return }
        let previous = pendingWrite,database = store
        pendingWrite = Task { [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority:.utility) { try database.saveUsage(interval) }.value
                self?.onChange?()
            } catch { self?.onError?(error) }
        }
    }
    func flush() async { await pendingWrite?.value;pendingWrite = nil }

    func transition(to app:AppUsageIdentity, at date:Date) throws {
        let boundary = max(date,current?.end ?? date)
        if current?.app == app { try checkpoint(at:boundary); return }
        try checkpoint(at:boundary)
        let next = AppUsageInterval(app:app,start:boundary,end:boundary)
        try save(next); current = next; onChange?()
    }
    func checkpoint(at date:Date) throws {
        guard var interval = current else { return }
        interval.end = max(interval.end,date)
        try save(interval); current = interval; onChange?()
    }
    func stop(at date:Date) throws {
        defer { current = nil; onChange?() }
        try checkpoint(at:date)
    }
}

/// Small projection of legacy frame metadata; never loads screenshot pixels or OCR.
struct CapturedAppMoment: Decodable, Identifiable, Sendable {
    let id: String
    let appName: String
    let bundleID: String
    let timestamp: Date
    let sessionID: String?
    let continuityID: String?
    var endTimestamp:Date?
    init(_ frame:MemoryFrame) {
        id = frame.id; appName = frame.appName; bundleID = frame.bundleID
        timestamp = frame.timestamp; sessionID = frame.sessionID; continuityID = frame.continuityID;endTimestamp = frame.endTimestamp
    }
}
