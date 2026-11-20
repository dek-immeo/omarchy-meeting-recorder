import AVFoundation

@main
enum LiveTranscriptTests {
    @MainActor
    static func wait(_ preview: LiveTranscript, until condition: () -> Bool) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            if preview.status.contains("utilgængelig") { throw RecorderError(preview.status) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RecorderError("Timed out waiting for live text: \(preview.status), \(preview.lines.map(\.text))")
    }

    @MainActor
    static func main() async throws {
        func endpoint(_ input: String) -> String? {
            AzureLiveSettings(endpoint: input, key: "test", language: "da-DK")?.endpoint
        }
        let route = "/speech/recognition/conversation/cognitiveservices/v1"
        precondition(endpoint("https://westeurope.api.cognitive.microsoft.com/") == "wss://westeurope.stt.speech.microsoft.com" + route)
        precondition(endpoint("https://sample.cognitiveservices.azure.com/") == "wss://sample.cognitiveservices.azure.com/stt" + route)
        precondition(endpoint("https://fake.org/") == nil && endpoint("http://sample.cognitiveservices.azure.com/") == nil)
        precondition(endpoint("https://sample.cognitiveservices.azure.com/?secret=x") == nil)
        precondition(endpoint("https://user@sample.cognitiveservices.azure.com/") == nil)
        let args = CommandLine.arguments
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preview = LiveTranscript()
        let start = hostSeconds()
        let inputs = try args[3...4].map { try AVAudioFile(forReading: URL(fileURLWithPath: $0)) }
        let tracks = try zip(Track.allCases, inputs).map { source, input in
            try WaveTrack(url: folder.appendingPathComponent(source.filename),
                          rate: input.processingFormat.sampleRate, channels: input.processingFormat.channelCount, start: start)
        }
        func append(seconds: Int) throws {
            for (input, track) in zip(inputs, tracks) {
                let rate = input.processingFormat.sampleRate
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(rate))!
                for _ in 0..<seconds {
                    let time = Double(input.framePosition) / rate
                    try input.read(into: buffer)
                    _ = try track.append(buffer, at: start + time)
                }
            }
        }

        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: args[1])
        preview.start(folder: folder, process: worker, cache: URL(fileURLWithPath: args[2])) { tracks.map(\.frames) }
        try append(seconds: 8)
        try await wait(preview) { preview.lines.contains { $0.source == "Mikrofon" && $0.text.lowercased().contains("office") } }
        let beforePause = preview.lines.map(\.id)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(preview.lines.map(\.id) == beforePause)
        try append(seconds: 10)
        try await wait(preview) { preview.lines.contains { $0.source == "Systemlyd" && $0.text.lowercased().contains("directory") } }
        precondition(preview.lines.map(\.ms) == preview.lines.map(\.ms).sorted())
        precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Transskription.md").path))
        let captured = preview.lines
        preview.cancel()
        await preview.finish(keepingLines: true)
        precondition(!worker.isRunning && preview.lines == captured && preview.partials.isEmpty)
        for track in tracks { try track.finish(at: start + 18) }

        let unavailable = Process()
        unavailable.executableURL = folder.appendingPathComponent("missing-worker")
        preview.start(folder: folder, process: unavailable) { [0, 0] }
        try await wait(preview) { preview.status.contains("utilgængelig") }
        preview.cancel()
        await preview.finish()
        print("Live captions verified on both open WAV writers before stop, with pause, cleanup and worker failure.")
    }
}
