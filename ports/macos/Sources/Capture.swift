import AVFoundation
import ScreenCaptureKit

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let folder: URL
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var tapInstalled = false
    private var routeObserver: NSObjectProtocol?
    private let io = DispatchQueue(label: "meeting-recorder.audio")
    // Access the following state only on io.
    private var tracks: [Track: WaveTrack] = [:]
    private var lastMeter: [Track: Double] = [:]
    private var pendingPeak: [Track: Float] = [:]
    private var failure: Error?
    private var finishing = false
    private let meter: (Track, Float) -> Void
    private let interrupted: () -> Void

    init(folder: URL, meter: @escaping (Track, Float) -> Void, interrupted: @escaping () -> Void) {
        self.folder = folder
        self.meter = meter
        self.interrupted = interrupted
    }

    static func displayWithPermissions() async throws -> SCDisplay {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError("Giv Meeting Recorder adgang til mikrofonen i Systemindstillinger → Anonymitet & sikkerhed → Mikrofon.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError("Systemlyd kræver adgang til skærm- og systemlydoptagelse. Kontrollér tilladelsen i Systemindstillinger → Anonymitet & sikkerhed, og åbn appen igen.\n\(error.localizedDescription)")
        }
        guard let display = content.displays.first else { throw RecorderError("Mac’en har ingen tilgængelig skærm til optagelse af systemlyd.") }
        return display
    }

    func start(display: SCDisplay) async throws {
        let mic = engine.inputNode
        let format = mic.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw RecorderError("Vælg en tilgængelig mikrofon i Mac’ens lydindstillinger.")
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // ScreenCaptureKit on Ventura needs a display filter. Only attach an audio output.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: io)
        self.stream = capture

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = hostSeconds()
        try io.sync {
            tracks[.microphone] = try WaveTrack(url: folder.appendingPathComponent(Track.microphone.filename),
                                               rate: format.sampleRate, channels: format.channelCount, start: start)
            tracks[.system] = try WaveTrack(url: folder.appendingPathComponent(Track.system.filename), rate: 48_000, channels: 2, start: start)
        }
        mic.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self, buffer.frameLength > 0 else { return }
            guard time.isHostTimeValid, let copy = copyMicrophoneBuffer(buffer) else {
                self.io.async { self.fail(RecorderError("Mikrofonens lyd kunne ikke læses.")) }
                return
            }
            let timestamp = AVAudioTime.seconds(forHostTime: time.hostTime)
            self.io.async { self.write(copy, to: .microphone, at: timestamp) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.io.async { self.fail(RecorderError("Mikrofonens konfiguration blev ændret. Optagelsen er stoppet.")) }
        }
        try await capture.startCapture()
    }

    // Called on io.
    private func write(_ pcm: AVAudioPCMBuffer, to source: Track, at time: Double) {
        guard failure == nil, !finishing, let track = tracks[source] else { return }
        do {
            let peak = try track.append(pcm, at: time)
            pendingPeak[source] = max(peak, pendingPeak[source] ?? 0)
            let now = hostSeconds()
            if now - (lastMeter[source] ?? 0) >= 0.08 {
                meter(source, pendingPeak[source] ?? 0)
                pendingPeak[source] = 0
                lastMeter[source] = now
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        guard failure == nil, !finishing else { return }
        failure = error
        interrupted()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0, !finishing, failure == nil else { return }
        do {
            try write(systemPCM(sampleBuffer), to: .system, at: sampleBuffer.presentationTimeStamp.seconds)
        } catch { fail(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        io.async { self.fail(error) }
    }

    func stop() async -> String? {
        let end = hostSeconds()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if tapInstalled {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let capture = stream
        stream = nil
        // Flush already queued buffers before closing the writers.
        io.sync { finishing = true }
        var stopError: Error?
        if let capture {
            do { try await capture.stopCapture() } catch { stopError = error }
        }
        let streamError = stopError
        return io.sync {
            var problems = [String]()
            if let error = failure ?? streamError { problems.append(error.localizedDescription) }
            for source in Track.allCases {
                guard let track = tracks[source] else { continue }
                if !track.hasSamples { problems.append("\(source.filename) modtog ingen lyddata.") }
                do { try track.finish(at: end) } catch { problems.append(error.localizedDescription) }
            }
            tracks.removeAll()
            return problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }
}
