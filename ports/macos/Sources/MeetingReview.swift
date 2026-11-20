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
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var variants: [String] = []
    @State private var variant = ""
    @State private var lines: [TranscriptLine] = []
    @State private var markdown = ""
    @State private var audioError: String?
    @State private var textError: String?
    @State private var query = ""
    @State private var showSummary = false

    @Environment(\.colorScheme) private var scheme
    @State private var envelope = MeetingEnvelope()
    @State private var speakers: [String] = []
    @State private var selectedSpeaker: String?
    private var palette: RecorderPalette { RecorderPalette(scheme) }

    private var filtered: [TranscriptLine] {
        lines.filter { line in
            (selectedSpeaker == nil || line.speaker == selectedSpeaker)
                && (query.isEmpty || line.text.localizedCaseInsensitiveContains(query) || line.speaker.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            HStack(alignment: .top, spacing: 0) {
                if !compact {
                    sidebar
                    Divider()
                }
                VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                    HStack {
                        Text(meetingTitle).font(recorderHeading).lineLimit(2).textSelection(.enabled)
                            .help(selection.folder.lastPathComponent)
                        Spacer()
                        if compact { detailsMenu }
                    }
                    if !lines.isEmpty {
                        Picker("Visning", selection: $showSummary) {
                            Text("Transskription").tag(false)
                            Text("Opsummering").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if showSummary && !lines.isEmpty {
                        MeetingSummaryPane(transcript: selection.folder.appendingPathComponent(variant), markdown: markdown)
                            .id(variant)
                    } else {
                        transcriptContent
                    }
                }.padding(compact ? 14 : 22)
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .background(palette.canvas).foregroundStyle(palette.ink).tint(palette.accent)
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
                if let preview = try? await MeetingEnvelope.load(folder: selection.folder, duration: duration), !Task.isCancelled {
                    envelope = preview
                }
            } catch { audioError = error.localizedDescription }
        }
        .onChange(of: variant) { name in
            selectedSpeaker = nil
            speakers = []
            guard !name.isEmpty else { return }
            do {
                markdown = try String(contentsOf: selection.folder.appendingPathComponent(name), encoding: .utf8)
                lines = TranscriptLine.read(markdown)
                var seen = Set<String>()
                speakers = lines.map(\.speaker).filter { seen.insert($0).inserted }
                textError = nil
            } catch { markdown = ""; lines = []; textError = error.localizedDescription }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mødedetaljer").font(.headline)
            if !variants.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Transskription").font(.caption).foregroundStyle(.secondary)
                    if variants.count > 1 {
                        Picker("Transskription", selection: $variant) {
                            ForEach(variants, id: \.self) { file in
                                Text(file == TranscriptionMode.azure.filename ? TranscriptionMode.azure.rawValue : "Lokal").tag(file)
                            }
                        }.labelsHidden().pickerStyle(.menu)
                    } else {
                        Text(variant == TranscriptionMode.azure.filename ? TranscriptionMode.azure.rawValue : "Lokal")
                    }
                }
            }
            if !speakers.isEmpty {
                Divider()
                Text("Talere").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        speakerButton(nil)
                        ForEach(speakers, id: \.self) { speaker in speakerButton(speaker) }
                    }
                }
            }
            Spacer()
            Button { NSWorkspace.shared.open(selection.folder) } label: {
                Label("Vis mødemappe", systemImage: "folder")
            }.buttonStyle(.borderless)
        }
        .padding(18).frame(width: 195).frame(maxHeight: .infinity)
        .background(palette.ink.opacity(0.035))
    }

    private var detailsMenu: some View {
        Menu {
            if variants.count > 1 {
                Picker("Transskription", selection: $variant) {
                    ForEach(variants, id: \.self) { file in
                        Text(file == TranscriptionMode.azure.filename ? TranscriptionMode.azure.rawValue : "Lokal").tag(file)
                    }
                }
            } else if let file = variants.first {
                Text(file == TranscriptionMode.azure.filename ? "Transskription · Azure Speech" : "Transskription · Lokal")
            }
            if !speakers.isEmpty {
                Picker("Talere", selection: $selectedSpeaker) {
                    Text("Alle talere").tag(nil as String?)
                    ForEach(speakers, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Button("Vis mødemappe") { NSWorkspace.shared.open(selection.folder) }
        } label: {
            Label("Mødedetaljer", systemImage: "sidebar.left")
        }.fixedSize()
    }

    @ViewBuilder private var transcriptContent: some View {
        playback
        HStack {
            Text("Transskription").font(.title3.bold())
            Spacer()
            if !markdown.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                } label: { Label("Kopiér", systemImage: "doc.on.doc") }
                .buttonStyle(.borderedProminent).recorderButtonShape()
                .help("Kopiér hele transskriptionen")
            }
        }
        if !lines.isEmpty {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Søg i tekst eller talere", text: $query).textFieldStyle(.plain)
            }.padding(10).recorderCard(palette)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if lines.isEmpty {
                    Text(textError ?? (markdown.isEmpty ? "Ingen transskription i mødemappen." : markdown)).textSelection(.enabled)
                } else if filtered.isEmpty {
                    Text("Ingen replikker matcher søgningen.").foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text(line.speaker).font(.headline).foregroundStyle(voiceColor(line.speaker))
                                Button(clockLabel(line.time)) { play(at: line.time) }
                                    .buttonStyle(.link).font(.caption.monospacedDigit()).disabled(player == nil)
                                    .accessibilityLabel("Afspil fra " + clockLabel(line.time))
                            }
                            Text(line.text).lineSpacing(3).textSelection(.enabled)
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).recorderCard(palette)
    }

    private var meetingTitle: String {
        let name = selection.folder.lastPathComponent
        // Only strip the recorder's generated suffix, including for old recording folders.
        return name.replacingOccurrences(of: #"^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}\.[0-9]{2}\.[0-9]{2})(.*?) [A-Fa-f0-9]{8}$"#,
                                         with: "$1$2", options: .regularExpression)
    }

    private func voiceColor(_ name: String) -> Color {
        let index = speakers.firstIndex(of: name) ?? 0
        return [palette.mic, palette.system, palette.accent][index % 3]
    }

    private func speakerButton(_ speaker: String?) -> some View {
        Button { selectedSpeaker = speaker } label: {
            HStack {
                Image(systemName: speaker == nil ? "person.2" : "person")
                Text(speaker ?? "Alle talere").lineLimit(2)
                Spacer()
                if speaker == selectedSpeaker { Image(systemName: "checkmark") }
            }.font(.callout).padding(7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(speaker == selectedSpeaker ? palette.accent.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(speaker == selectedSpeaker ? .isSelected : [])
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let current = player?.currentTime().seconds ?? 0
                let position = current.isFinite ? min(max(0, current), duration) : 0
                HStack(spacing: 12) {
                    Button {
                        if player?.rate != 0 { player?.pause() }
                        else if duration - position < 0.05 { play(at: 0) }
                        else { player?.play() }
                    } label: { Image(systemName: player?.rate ?? 0 > 0 ? "pause.fill" : "play.fill") }
                    .disabled(player == nil)
                    .accessibilityLabel(player?.rate ?? 0 > 0 ? "Pause" : "Afspil")
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            PlaybackWave(envelope: envelope, fraction: duration > 0 ? position / duration : 0, palette: palette)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                                    guard geo.size.width > 0 else { return }
                                    seek(to: duration * min(1, max(0, drag.location.x / geo.size.width)))
                                })
                        }.frame(height: 32)
                        Slider(value: Binding(get: { position }, set: { seek(to: $0) }), in: 0...max(duration, 0.001))
                            .controlSize(.mini).disabled(player == nil).accessibilityLabel("Afspilningsposition")
                    }
                    Text(clockLabel(position) + " / " + clockLabel(duration)).font(.caption.monospacedDigit())
                }
            }
            if let audioError { Text(audioError).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).recorderCard(palette)
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func play(at seconds: Double) {
        seek(to: seconds)
        player?.play()
    }
}

private struct MeetingSummaryPane: View {
    let transcript: URL
    let markdown: String
    @State private var text = ""
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error {
                Text(error).textSelection(.enabled)
                Button("Prøv igen") { attempt += 1 }
            } else if text.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Skriver opsummering på denne Mac …")
                }
            } else {
                HStack {
                    Spacer()
                    Button("Kopiér opsummering") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                            if line.hasPrefix("#") {
                                Text(String(line.drop(while: { $0 == "#" || $0 == " " })))
                                    .font(.headline).padding(.top, 6)
                            } else if !line.isEmpty {
                                Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: attempt) {
            text = ""
            error = nil
            do {
                let result = try await MeetingSummary.saved(for: transcript, markdown: markdown)
                try Task.checkCancellation()
                text = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
