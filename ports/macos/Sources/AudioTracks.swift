import AVFoundation
import CoreMedia

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Track: CaseIterable {
    case microphone, system
    var filename: String { self == .microphone ? "Mikrofon.wav" : "Systemlyd.wav" }
}

func hostSeconds() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

// AVAudioEngine owns tap buffers and may recycle them after the tap returns.
func copyMicrophoneBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
    copy.frameLength = source.frameLength
    let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (src, dst) in zip(input, output) {
        guard let from = src.mData, let to = dst.mData, src.mDataByteSize <= dst.mDataByteSize else { return nil }
        memcpy(to, from, Int(src.mDataByteSize))
    }
    return copy
}

func systemPCM(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
    let count = CMSampleBufferGetNumSamples(sample)
    guard count > 0, let description = sample.formatDescription,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
          let format = AVAudioFormat(streamDescription: asbd),
          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
    else { throw RecorderError("Systemlydens format kunne ikke læses.") }
    pcm.frameLength = AVAudioFrameCount(count)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
    guard status == noErr else { throw RecorderError("Systemlyden kunne ikke afkodes (\(status)).") }
    return pcm
}

// Each file has the same time origin. Timestamps preserve initial silence and
// gaps when the output device sleeps or ScreenCaptureKit delivers no packets.
final class WaveTrack {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let silence: AVAudioPCMBuffer
    let start: Double
    private var frames: Int64 = 0
    private(set) var hasSamples = false

    init(url: URL, rate: Double, channels: AVAudioChannelCount, start: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { throw RecorderError("Lydformatet kunne ikke oprettes.") }
        self.format = format
        self.silence = silence
        self.start = start
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for c in 0..<Int(channels) {
            silence.floatChannelData![c].initialize(repeating: 0, count: Int(silence.frameCapacity))
        }
    }

    private func pad(to target: Int64) throws {
        while frames < target {
            silence.frameLength = AVAudioFrameCount(min(target - frames, Int64(silence.frameCapacity)))
            try file.write(from: silence)
            frames += Int64(silence.frameLength)
        }
    }

    func finish(at end: Double) throws {
        try pad(to: Int64((max(0, end - start) * format.sampleRate).rounded()))
    }

    func append(_ input: AVAudioPCMBuffer, at seconds: Double) throws -> Float {
        guard seconds.isFinite, abs(seconds - hostSeconds()) < 86_400 else {
            throw RecorderError("Lydkildens tidsstempel kunne ikke læses.")
        }
        guard input.format.commonFormat == .pcmFormatFloat32, input.format.channelCount == format.channelCount,
              input.format.sampleRate == format.sampleRate, let data = input.floatChannelData else {
            throw RecorderError("Lydkilden har skiftet format. Start en ny optagelse med den valgte enhed.")
        }
        let offset = Int64(((seconds - start) * format.sampleRate).rounded())
        // Ignore small packet-timestamp jitter, but preserve real gaps and trim overlaps.
        let first = abs(offset - frames) <= 2 ? frames : offset
        try pad(to: first)
        let skip = min(Int64(input.frameLength), max(0, frames - first))
        let count = Int(input.frameLength) - Int(skip)
        guard count > 0 else { return 0 }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let dest = pcm.floatChannelData else { throw RecorderError("Der er ikke nok hukommelse til lydsporet.") }
        pcm.frameLength = AVAudioFrameCount(count)
        let interleaved = input.format.isInterleaved
        let channels = Int(format.channelCount)
        var peak: Float = 0
        for c in 0..<channels {
            let src = interleaved ? data[0] + c : data[c]
            let stride = interleaved ? channels : 1
            for i in 0..<count {
                let value = src[(i + Int(skip)) * stride]
                dest[c][i] = value
                peak = max(peak, abs(value))
            }
        }
        try file.write(from: pcm)
        frames += Int64(count)
        hasSamples = true
        return min(1, peak)
    }
}
