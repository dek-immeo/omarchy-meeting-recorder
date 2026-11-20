import AVFoundation

@main
enum MeetingWorkflowTests {
    static func makeTrack(_ url: URL, rate: Double, start: Double, amplitude: Float) throws {
        let wav = try WaveTrack(url: url, rate: rate, channels: 1, start: start)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10))!
        block.frameLength = block.frameCapacity
        block.floatChannelData![0].initialize(repeating: amplitude, count: Int(block.frameLength))
        var clock = RecordingClock()
        func write(_ at: Double) throws {
            if let t = clock.sampleTime(at) { _ = try wav.append(block, at: t) }
        }
        try write(start)
        clock.pause(at: start + 0.1)
        try write(start + 0.2)
        precondition(abs(clock.endTime(start + 3) - start - 0.1) < 0.0001)
        clock.resume(at: start + 8.1)
        try write(start + 0.3) // delayed callback from before resume
        try write(start + 8.1)
        try wav.finish(at: clock.endTime(start + 8.2))
    }

    static func checkpoint(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func main() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        checkpoint("Writing both paused tracks")
        let start = hostSeconds()
        for (track, rate) in [(Track.microphone, 44_100.0), (.system, 48_000.0)] {
            let file = temp.appendingPathComponent(track.filename)
            try makeTrack(file, rate: rate, start: start, amplitude: 0.4)
            let saved = try AVAudioFile(forReading: file)
            precondition(saved.length == Int64(rate / 5))
        }
        checkpoint("Loading captured tracks for playback")
        let mix = try await MeetingAudio.composition(folder: temp)
        let tracks = try await mix.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 2)
        for track in tracks {
            let range = try await track.load(.timeRange)
            precondition(range.start.seconds == 0 && abs(range.duration.seconds - 0.2) < 0.001)
        }

        let wave = try await MeetingEnvelope.load(folder: temp, duration: 0.4)
        for channel in [wave.microphone, wave.system] {
            precondition(channel.count == 360)
            precondition(abs(channel[0] - 0.4) < 0.001 && channel[359] == 0)
        }

        checkpoint("Encoding M4A fixture")
        let input = temp.appendingPathComponent("sample.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", temp.appendingPathComponent(Track.microphone.filename).path, input.path]
        try convert.run()
        convert.waitUntilExit()
        precondition(convert.terminationStatus == 0)
        let imported = temp.appendingPathComponent("imported")
        checkpoint("Importing compressed audio")
        try await MeetingFiles.importAudio(input, to: imported)
        checkpoint("Loading imported audio for playback")
        let importedMix = try await MeetingAudio.composition(folder: imported)
        let importedTracks = try await importedMix.loadTracks(withMediaType: .audio)
        precondition(importedTracks.count == 1)
        let decoded = try AVAudioFile(forReading: imported.appendingPathComponent("Import.wav"))
        precondition(decoded.length > 0 && FileManager.default.fileExists(atPath: input.path))
        let importedWave = try await MeetingEnvelope.load(folder: imported, duration: 0.2)
        precondition(importedWave.microphone.contains { $0 > 0 } && importedWave.system.isEmpty)
        let lines = TranscriptLine.read("**[00:00:00] Mikrofon · Taler 1**  \nHej\n\n**[00:00:00.152] Systemlyd · Taler 2**  \nJa\npræcis.\n")
        precondition(lines.count == 2 && lines[0].time == 0 && lines[1].time == 0.152 && lines[1].text == "Ja\npræcis.")
        let history = temp.appendingPathComponent("history")
        let empty = try PastMeeting.load(from: history)
        precondition(empty.isEmpty)
        for (name, files) in [
            ("2025-01-02 09.00.00 Plan ABCDEF12", ["Transskription.md", "Transskription-Azure.md", "Transskription-Azure-Opsummering.md"]),
            ("2025-01-01 11.00.00 1234abcd", ["Import.wav"]),
            ("other", ["unrelated.md"])
        ] {
            let meeting = history.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
            for file in files { try Data().write(to: meeting.appendingPathComponent(file)) }
        }
        let past = try PastMeeting.load(from: history)
        precondition(past.count == 2 && past[0].title == "Plan" && past[0].hasSummary)
        precondition(past[0].transcript == "Transskription-Azure.md" && past[1].transcript == nil)
        print("Past meeting discovery, ordering and summary variant verified.")
        print("Pause, resume, WAV timing, two-track playback composition, compressed audio import and transcript timestamps verified.")
    }
}
