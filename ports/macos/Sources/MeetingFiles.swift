import AVFoundation

struct MeetingSelection: Hashable, Codable {
    let folder: URL
    var preferred: String? = nil
    var opensSummary: Bool? = nil
}

enum MeetingFiles {
    static var root: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Recorder", isDirectory: true)
    }

    static func newFolder(title: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = [stamp.string(from: Date()), title.map { String($0.prefix(40)) }, String(UUID().uuidString.prefix(8))]
            .compactMap { $0 }.joined(separator: " ")
        return root.appendingPathComponent(name, isDirectory: true)
    }

    static func importAudio(_ source: URL, to folder: URL) async throws {
        // Decode in blocks, retaining the original sample rate. The transcriber
        // downmixes and resamples imported and recorded tracks the same way.
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard input.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw RecorderError("Filen har ingen læsbar lyd.")
        }
        let fm = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        do {
            let output = try AVAudioFile(forWriting: staging.appendingPathComponent("Import.wav"), settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let length = input.length
            while input.framePosition < length {
                try Task.checkCancellation()
                let remaining = length - input.framePosition
                let count = AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity)))
                try input.read(into: buffer, frameCount: count)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                if buffer.frameLength < count { break }
            }
            guard output.length > 0 else { throw RecorderError("Filen indeholder ingen lyd.") }
        }
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: folder)
    }
}
