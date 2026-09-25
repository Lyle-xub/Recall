import AppKit
import AVFoundation

enum MicrophonePermission: Equatable {
    case notDetermined, authorized, denied, restricted
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        default: self = .denied
        }
    }
    var label: String {
        switch self { case .authorized: "Allowed"; case .notDetermined: "Not requested"; case .denied: "Not allowed"; case .restricted: "Restricted" }
    }
}

enum CapturePermissionError: LocalizedError {
    case microphone(MicrophonePermission)
    var errorDescription: String? {
        switch self {
        case .microphone(.restricted): "Microphone access is restricted on this Mac. Change the system restriction, or turn off Microphone in Recording settings."
        default: "Allow Recall in System Settings → Privacy & Security → Microphone, then try again. You can also turn off Microphone to record only the screen."
        }
    }
}

/// All recording entry points share the same permission policy. Never request
/// microphone access just to inspect settings or start a screen-only recording.
@MainActor enum CapturePermissions {
    static var microphone: MicrophonePermission { MicrophonePermission(AVCaptureDevice.authorizationStatus(for:.audio)) }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static func ensureMicrophone(enabled: Bool,
        status: @MainActor () -> MicrophonePermission = { microphone },
        request: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for:.audio) }) async throws {
        guard enabled else { return }
        switch status() {
        case .authorized: return
        case .notDetermined:
            guard await request() else { throw CapturePermissionError.microphone(.denied) }
        case let state: throw CapturePermissionError.microphone(state)
        }
    }
    static func openSettings(microphone: Bool) {
        let pane = microphone ? "Privacy_Microphone":"Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
