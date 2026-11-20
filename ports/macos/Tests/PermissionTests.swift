import Foundation
import ScreenCaptureKit

@main
enum PermissionTests {
    @MainActor
    static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RecorderError("Permission state did not settle")
    }

    @MainActor
    static func main() async throws {
        let settings = Recorder()
        settings.liveEnabled = true
        settings.speechEndpoint = "https://example.cognitiveservices.azure.com/"
        settings.speechLanguage = "da-DK"
        for live in TranscriptionMode.allCases {
            for final in TranscriptionMode.allCases {
                settings.liveProvider = live
                settings.mode = final
                settings.azureKey = ""
                precondition(settings.configured == (final == .local))
                precondition(settings.recordingConfigured == (live == .local && final == .local))
                settings.azureKey = "test-key"
                precondition(settings.configured && settings.recordingConfigured)
                precondition(settings.usesAzureLive == (live == .azure))
            }
        }
        precondition(settings.batchResource == "example")
        settings.speechEndpoint = "example"
        precondition(settings.liveSettings?.endpoint.hasPrefix("wss://example.cognitiveservices.azure.com/stt/") == true)
        settings.speechEndpoint = "https://westeurope.api.cognitive.microsoft.com/"
        settings.regionalResource = ""
        precondition(settings.liveSettings != nil && !settings.configured)
        settings.regionalResource = "example"
        precondition(settings.batchResource == "example" && settings.recordingConfigured)
        settings.speechLanguage = "invalid"
        precondition(!settings.recordingConfigured && settings.configured)
        settings.liveEnabled = false
        precondition(settings.recordingConfigured)
        settings.speechEndpoint = "https://example.org/"
        precondition(!settings.configured && settings.liveSettings == nil)

        var missing: CapturePermission? = .microphone
        var requested: [CapturePermission] = []
        var queries = 0
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let first = Recorder(checkPermission: { missing }, requestPermission: { requested.append($0) },
                             availableDisplay: { queries += 1; throw denied })
        for permission in [CapturePermission.microphone, .microphone, .screen, .screen] {
            missing = permission
            first.start()
            try await waitFor { first.phase == .ready }
            precondition(first.permissionIssue == permission && first.started == nil)
        }
        precondition(requested == [.microphone, .screen] && queries == 0)
        missing = nil
        first.start()
        try await waitFor { first.phase == .ready }
        precondition(first.permissionIssue == .screen && queries == 1)
        precondition(CapturePermission.from(NSError(domain: "Other", code: denied.code)) == nil)

        var pending: CheckedContinuation<SCDisplay, Error>?
        let second = Recorder(checkPermission: { nil }, requestPermission: { _ in preconditionFailure() },
                              availableDisplay: { try await withCheckedThrowingContinuation { pending = $0 } })
        second.start()
        try await waitFor { pending != nil }
        let outdated = pending!
        pending = nil
        second.stop()
        precondition(second.phase == .ready)
        second.start()
        try await waitFor { pending != nil }
        outdated.resume(throwing: denied)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(second.phase == .checking && second.permissionIssue == nil)
        await second.prepareToQuit()
        precondition(second.phase == .ready)
        pending!.resume(throwing: denied)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(second.phase == .ready && second.permissionIssue == nil)
        print("Denied access, retry, late completion, cancellation and Quit verified.")
    }
}
