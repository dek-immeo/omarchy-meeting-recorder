import AVFoundation

#if os(macOS)
import ScreenCaptureKit

@available(macOS 13, *)
func systemAudioConfiguration() -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    return configuration
}
#endif

func microphoneFormat(engine: AVAudioEngine) -> AVAudioFormat {
    engine.inputNode.outputFormat(forBus: 0)
}

#if os(iOS)
func configureRoomRecording(session: AVAudioSession) throws {
    try session.setCategory(.record, mode: .default)
}
#endif
