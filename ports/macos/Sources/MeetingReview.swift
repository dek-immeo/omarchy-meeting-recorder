import AVFoundation
import SwiftUI

struct TranscriptLine: Identifiable {
    let id: Int
    let time: Double
    let speaker: String
    let text: String

    static func read(_ markdown: String) -> [Self] {
        var lines: [Self] = []
        var header: (Double, String)?
        var body: [String] = []
        func finish() {
            if let (time, speaker) = header {
                let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(Self(id: lines.count, time: time, speaker: speaker, text: text)) }
            }
            body = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**["), line.hasSuffix("**"), let split = line.range(of: "] ") {
                let stamp = line.dropFirst(3)[..<split.lowerBound].split(separator: ":")
                if stamp.count == 3, let h = Int(stamp[0]), let m = Int(stamp[1]), let s = Double(stamp[2]),
                   h >= 0, (0..<60).contains(m), s >= 0, s < 60 {
                    finish()
                    header = (Double(h) * 3600 + Double(m) * 60 + s, String(line[split.upperBound...].dropLast(2)))
                    continue
                }
            }
            if header != nil { body.append(raw) }
        }
        finish()
        return lines
    }
}

enum MeetingAudio {
    static func composition(folder: URL) async throws -> AVMutableComposition {
        let mix = AVMutableComposition()
        let names = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Import.wav").path)
            ? ["Import.wav"] : Track.allCases.map(\.filename)
        for name in names {
            let asset = AVURLAsset(url: folder.appendingPathComponent(name))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let dest = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw RecorderError("Lydsporet \(name) kunne ikke åbnes.") }
            let range = try await source.load(.timeRange)
            try dest.insertTimeRange(range, of: source, at: .zero)
        }
        return mix
    }
}

private func clockLabel(_ value: Double) -> String {
    let t = Int(max(0, value))
    return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
}

struct MeetingReview: View {
    let selection: MeetingSelection
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var variants: [String] = []
    @State private var variant = ""
    @State private var lines: [TranscriptLine] = []
    @State private var markdown = ""
    @State private var audioError: String?
    @State private var textError: String?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selection.folder.lastPathComponent).font(.headline).textSelection(.enabled)
                Spacer()
                Button("Luk") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if variants.count > 1 {
                Picker("Transskription", selection: $variant) {
                    ForEach(variants, id: \.self) { file in
                        Text(file == TranscriptionMode.azure.filename ? "Azure" : "Lokal").tag(file)
                    }
                }.pickerStyle(.segmented)
            }
            if let audioError { Text(audioError).foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let current = player?.currentTime().seconds ?? 0
                let position = current.isFinite ? min(max(0, current), duration) : 0
                HStack {
                    Button {
                        if player?.rate != 0 { player?.pause() }
                        else if duration - position < 0.05 { play(at: 0) }
                        else { player?.play() }
                    } label: {
                        Image(systemName: player?.rate == 0 ? "play.fill" : "pause.fill")
                    }
                    .disabled(player == nil).accessibilityLabel(player?.rate == 0 ? "Afspil" : "Pause")
                    Slider(value: Binding(get: { position }, set: { seek(to: $0) }), in: 0...max(duration, 0.001))
                        .disabled(player == nil).accessibilityLabel("Afspilningsposition")
                    Text(clockLabel(position) + " / " + clockLabel(duration)).font(.caption.monospacedDigit())
                }
            }
            if !lines.isEmpty {
                TextField("Søg i tekst eller talere", text: $query).textFieldStyle(.roundedBorder)
                List(lines.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.speaker.localizedCaseInsensitiveContains(query) }) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Button(clockLabel(line.time)) { play(at: line.time) }
                            .buttonStyle(.link).monospacedDigit().disabled(player == nil)
                            .accessibilityLabel("Afspil fra " + clockLabel(line.time))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.speaker).font(.caption.bold()).foregroundStyle(.secondary)
                            Text(line.text).textSelection(.enabled)
                        }
                    }.padding(.vertical, 3)
                }
            } else {
                ScrollView {
                    Text(textError ?? (markdown.isEmpty ? "Ingen transskription i mødemappen." : markdown))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Vis mødemappe") { NSWorkspace.shared.open(selection.folder) }
                Spacer()
                if !markdown.isEmpty {
                    Button("Kopiér transskription") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                    }
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 360, idealHeight: 480)
        .padding(20)
        .task {
            variants = TranscriptionMode.allCases.map(\.filename).filter {
                FileManager.default.fileExists(atPath: selection.folder.appendingPathComponent($0).path)
            }
            variant = selection.preferred.flatMap { variants.contains($0) ? $0 : nil } ?? variants.first ?? ""
            do {
                let mix = try await MeetingAudio.composition(folder: selection.folder)
                let length = try await mix.load(.duration)
                try Task.checkCancellation()
                duration = length.seconds.isFinite ? length.seconds : 0
                player = AVPlayer(playerItem: AVPlayerItem(asset: mix))
            } catch { audioError = error.localizedDescription }
        }
        .onChange(of: variant) { name in
            guard !name.isEmpty else { return }
            do {
                markdown = try String(contentsOf: selection.folder.appendingPathComponent(name), encoding: .utf8)
                lines = TranscriptLine.read(markdown)
                textError = nil
            } catch { markdown = ""; lines = []; textError = error.localizedDescription }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func play(at seconds: Double) {
        seek(to: seconds)
        player?.play()
    }
}
