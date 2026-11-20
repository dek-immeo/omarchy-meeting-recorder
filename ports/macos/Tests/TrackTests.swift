import AVFoundation

@main
struct TrackTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = hostSeconds()
        for source in Track.allCases {
            let channels: AVAudioChannelCount = source == .microphone ? 1 : 2
            let rate = source == .microphone ? 44_100.0 : 48_000.0
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            pcm.frameLength = 100
            for c in 0..<Int(channels) {
                pcm.floatChannelData![c].initialize(repeating: c == 0 ? 0.5 : -0.25, count: 100)
            }
            let input: AVAudioPCMBuffer
            if source == .microphone {
                input = copyMicrophoneBuffer(pcm)!
                pcm.floatChannelData![0][0] = 0
            } else {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                precondition(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
                    makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                    sampleCount: 100, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
                precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil,
                    blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr)
                input = try systemPCM(sample!)
            }
            let url = dir.appendingPathComponent(source.filename)
            do {
                let track = try WaveTrack(url: url, rate: rate, channels: channels, start: start)
                let peak = try track.append(input, at: start + 50 / rate)
                precondition(peak == 0.5)
                _ = try track.append(input, at: start + 140 / rate)
                try track.finish(at: start + 300 / rate)
            }
            let file = try AVAudioFile(forReading: url)
            precondition(file.length == 300 && file.fileFormat.sampleRate == rate)
            let saved = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 300)!
            try file.read(into: saved)
            for c in 0..<Int(channels) {
                for i in 0..<300 {
                    let expected: Float = (50..<240).contains(i) ? (c == 0 ? 0.5 : -0.25) : 0
                    precondition(abs(saved.floatChannelData![c][i] - expected) < 0.0001)
                }
            }
        }
        print("Both WAV tracks retained channel content, timing and silence.")
    }
}
