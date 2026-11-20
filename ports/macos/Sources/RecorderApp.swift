import AppKit
import SwiftUI

@MainActor
final class Recorder: ObservableObject {
    enum Phase { case ready, starting, recording, stopping, transcribing }
    @Published private(set) var phase = Phase.ready
    @Published private(set) var started: Date?
    @Published private(set) var lastFolder: URL?
    @Published private(set) var message: String?
    struct Reading { let level: Float; let date: Date }
    @Published private(set) var meters: [Track: Reading] = [:]
    @Published private(set) var transcriptionStatus = ""
    private let transcriber = Transcription()
    private var quitting = false
    private var capture: Capture?
    private var transition: Task<Void, Never>?
    private var stopRequested = false

    func start() {
        guard phase == .ready else { return }
        phase = .starting
        message = nil
        meters = [:]
        stopRequested = false
        transition = Task {
            do {
                let display = try await Capture.displayWithPermissions()
                if stopRequested { phase = .ready; return }
                let music = try FileManager.default.url(for: .musicDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let folder = music.appendingPathComponent("Meeting Recorder", isDirectory: true)
                    .appendingPathComponent("\(stamp.string(from: Date())) \(UUID().uuidString.prefix(8))", isDirectory: true)
                let session = Capture(folder: folder, meter: { [weak self] track, peak in
                    Task { @MainActor in self?.meters[track] = Reading(level: peak, date: Date()) }
                }, interrupted: { [weak self] in Task { @MainActor in self?.stop() } })
                capture = session
                started = Date()
                try await session.start(display: display)
                phase = .recording
                if stopRequested { await finish() }
            } catch {
                let reason = error.localizedDescription
                if capture != nil { await finish(transcribe: false) }
                message = reason
                phase = .ready
                started = nil
            }
        }
    }

    func stop() {
        if phase == .starting { stopRequested = true; return }
        guard phase == .recording else { return }
        phase = .stopping
        transition = Task { await finish() }
    }

    private func finish(transcribe: Bool = true) async {
        phase = .stopping
        if let capture {
            message = await capture.stop()
            if FileManager.default.fileExists(atPath: capture.folder.path) { lastFolder = capture.folder }
        }
        let folder = capture?.folder
        capture = nil
        meters = [:]
        phase = .ready
        started = nil
        if transcribe, !quitting, let folder, message == nil {
            await writeTranscript(in: folder)
        }
    }

    private func writeTranscript(in folder: URL) async {
        phase = .transcribing
        lastFolder = folder
        message = nil
        transcriptionStatus = "Klargør lokal transskription …"
        do {
            try await transcriber.run(folder: folder) { self.transcriptionStatus = $0 }
        } catch { message = error.localizedDescription }
        phase = .ready
    }

    func selectRecording() {
        guard phase == .ready else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Transskriber"
        panel.message = "Vælg mødemappen med Mikrofon.wav og Systemlyd.wav."
        panel.directoryURL = lastFolder?.deletingLastPathComponent() ?? FileManager.default
            .urls(for: .musicDirectory, in: .userDomainMask).first?.appendingPathComponent("Meeting Recorder")
        if panel.runModal() == .OK, let folder = panel.url {
            phase = .transcribing
            transition = Task { await writeTranscript(in: folder) }
        }
    }

    func cancelTranscription() { transcriber.cancel() }

    func prepareToQuit() async {
        quitting = true
        cancelTranscription()
        stop()
        await transition?.value
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.phase != .ready else { return .terminateNow }
        Task {
            await recorder.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Meter: View {
    let title: String
    let icon: String
    let reading: Recorder.Reading?
    let date: Date
    var body: some View {
        let peak = reading.flatMap { date.timeIntervalSince($0.date) < 0.5 ? $0.level : nil } ?? 0
        let db = 20 * log10(max(Double(peak), 0.001))
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            Text(title).frame(width: 82, alignment: .leading)
            ProgressView(value: max(0, min(1, (db + 60) / 60))).tint(.accentColor)
            Text(peak > 0.001 ? String(format: "%.0f dB", db) : "— dB")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecorderView: View {
    @ObservedObject var recorder: Recorder
    var body: some View {
        let phase = recorder.phase
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Circle().fill(phase == .recording ? Color.red : .secondary).frame(width: 9, height: 9)
                Text(status).font(.title2.bold())
                Spacer()
                if let started = recorder.started {
                    TimelineView(.periodic(from: started, by: 1)) { time in
                        let seconds = max(0, Int(time.date.timeIntervalSince(started)))
                        Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                            .monospacedDigit().font(.title2)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 0.2)) { time in
                VStack(spacing: 14) {
                    Meter(title: "Mikrofon", icon: "mic", reading: recorder.meters[.microphone], date: time.date)
                    Meter(title: "Systemlyd", icon: "speaker.wave.2", reading: recorder.meters[.system], date: time.date)
                }
            }
            Divider()
            if phase == .transcribing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(recorder.transcriptionStatus).lineLimit(2)
                    Spacer()
                    Button("Annuller") { recorder.cancelTranscription() }
                }
            }
            if let message = recorder.message {
                Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
            }
            HStack {
                Button {
                    if phase == .ready { recorder.start() } else { recorder.stop() }
                } label: {
                    Label(phase == .recording || phase == .stopping ? "Stop optagelse" : "Start optagelse",
                          systemImage: phase == .recording || phase == .stopping ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(phase != .ready && phase != .recording)
                Spacer()
                if let folder = recorder.lastFolder {
                    Button("Vis seneste optagelse") { NSWorkspace.shared.open(folder) }
                }
            }
            if phase == .ready {
                HStack {
                    Button("Transskriber tidligere optagelse…") { recorder.selectRecording() }
                    Spacer()
                    if let file = recorder.lastFolder?.appendingPathComponent("Transskription.md"),
                       FileManager.default.fileExists(atPath: file.path) {
                        Button("Åbn transskription") { NSWorkspace.shared.open(file) }
                    }
                }
            }
        }
        .padding(24).frame(minWidth: 445, idealWidth: 480)
    }
    private var status: String {
        switch recorder.phase {
        case .ready: return "Klar til optagelse"
        case .starting: return "Starter optagelse…"
        case .recording: return "Optager"
        case .stopping: return "Gemmer optagelse…"
        case .transcribing: return "Transskriberer"
        }
    }
}

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Meeting Recorder", id: "recorder") {
            RecorderView(recorder: delegate.recorder)
        }.windowResizability(.contentSize)
    }
}
