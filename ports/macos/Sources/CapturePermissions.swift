import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum CapturePermission: Error, Hashable {
    case microphone, screen

    var title: String { self == .microphone ? "Mikrofon" : "Skærm- og systemlydoptagelse" }
    var settings: URL {
        let pane = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    static func missing() async -> Self? {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return .microphone }
        return CGPreflightScreenCaptureAccess() ? nil : .screen
    }

    func request() {
        // macOS owns the prompt. A slow or unanswered dialog must never hold up Quit or Retry.
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
        case .screen:
            DispatchQueue.global(qos: .userInitiated).async { _ = CGRequestScreenCaptureAccess() }
        }
    }

    static func from(_ error: Error) -> Self? {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue ? .screen : nil
    }
}
