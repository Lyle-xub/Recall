import AppKit

struct CaptureApplication: Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String
    let title: String
    static let desktop = Self(pid:0,name:"Desktop",bundleID:"",title:"Desktop")
}

enum CaptureForeground {
    static func choose(frontmost:CaptureApplication?,visibleWindows:[CaptureApplication],ownPID:pid_t)->CaptureApplication {
        guard let frontmost else { return .desktop }
        if frontmost.pid != ownPID { return frontmost }
        // Do not skip private applications here. They must remain the target so
        // the caller can suppress capture, rather than attribute it to another app.
        return visibleWindows.first { $0.pid != ownPID } ?? .desktop
    }
    @MainActor static func resolve(app:NSRunningApplication?,displayID:CGDirectDisplayID?)->CaptureApplication {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let bounds = displayID.map { CGDisplayBounds($0) }
        let candidates = windows.compactMap { entry -> CaptureApplication? in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let owner = NSRunningApplication(processIdentifier:pid),
                  owner.activationPolicy == .regular,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation:dictionary),rect.width > 40,rect.height > 40,
                  bounds.map({ $0.intersects(rect) }) ?? true else { return nil }
            let name = owner.localizedName ?? "Application"
            return CaptureApplication(pid:pid,name:name,bundleID:owner.bundleIdentifier ?? "",title:entry[kCGWindowName as String] as? String ?? name)
        }
        let frontmost = app.map { app in
            CaptureApplication(pid:app.processIdentifier,name:app.localizedName ?? "Desktop",bundleID:app.bundleIdentifier ?? "",title:candidates.first { $0.pid == app.processIdentifier }?.title ?? app.localizedName ?? "Desktop")
        }
        return choose(frontmost:frontmost,visibleWindows:candidates,ownPID:ProcessInfo.processInfo.processIdentifier)
    }
}
