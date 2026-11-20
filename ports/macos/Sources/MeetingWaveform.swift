import Accelerate
import AVFoundation
import SwiftUI

struct MeetingEnvelope {
    var microphone: [Float] = []
    var system: [Float] = []

    // Sample a short PCM window per display bin. Preview work stays bounded even for long meetings.
    static func load(folder: URL, duration: Double) async throws -> Self {
        guard duration.isFinite, duration > 0 else { return Self() }
        func peaks(_ name: String) throws -> [Float] {
            let file = try AVAudioFile(forReading: folder.appendingPathComponent(name),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let count = 360
            let span = duration * format.sampleRate / Double(count)
            let capacity = AVAudioFrameCount(min(2048, max(1, ceil(span))))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
            var bins = [Float](repeating: 0, count: count)
            for i in bins.indices {
                try Task.checkCancellation()
                let start = AVAudioFramePosition(Double(i) * span)
                guard start < file.length else { break }
                file.framePosition = start
                try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(clamping: file.length - start)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { continue }
                for ch in 0..<Int(format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[ch], 1, &peak, vDSP_Length(buffer.frameLength))
                    bins[i] = max(bins[i], peak)
                }
            }
            return bins
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("Import.wav").path) {
            return Self(microphone: try peaks("Import.wav"))
        }
        return Self(microphone: try peaks(Track.microphone.filename), system: try peaks(Track.system.filename))
    }
}

struct PlaybackWave: View {
    let envelope: MeetingEnvelope
    let fraction: Double
    let palette: RecorderPalette

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            context.fill(Path(CGRect(x: 0, y: mid, width: size.width, height: 1)), with: .color(palette.ink.opacity(0.2)))
            func draw(_ data: [Float], above: Bool, color: Color) {
                guard !data.isEmpty else { return }
                let step = size.width / CGFloat(data.count)
                var bars = Path()
                for (index, value) in data.enumerated() {
                    let height = min(1, sqrt(CGFloat(max(0, value)))) * (mid - 2)
                    bars.addRect(CGRect(x: CGFloat(index) * step, y: above ? mid - height : mid, width: step, height: height))
                }
                context.fill(bars, with: .color(color))
            }
            draw(envelope.microphone, above: true, color: palette.mic)
            let single = envelope.system.isEmpty
            draw(single ? envelope.microphone : envelope.system, above: false, color: single ? palette.mic : palette.system)
            let x = min(max(0, fraction * size.width), max(0, size.width - 2))
            context.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(palette.ink))
        }.accessibilityHidden(true)
    }
}
