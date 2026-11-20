import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScreenCaptureKit

@MainActor
final class Recorder: ObservableObject {
    enum Phase { case ready, checking, starting, recording, paused, stopping, importing, transcribing }
    @Published private(set) var phase = Phase.ready
    @Published private(set) var pausedAt: Date?
    @Published private(set) var started: Date?
    @Published private(set) var lastFolder: URL?
    @Published private(set) var message: String?
    struct Reading { let level: Float; let date: Date }
    @Published private(set) var meters: [Track: Reading] = [:]
    @Published private(set) var transcriptionStatus = ""
    @Published var mode = TranscriptionMode.local
    @Published var azureResource = UserDefaults.standard.string(forKey: "azureSpeechResource") ?? ""
    @Published var azureKey = ""
    @Published private(set) var transcriptFile: URL?
    var configured: Bool {
        mode == .local || (azureResource.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"#, options: .regularExpression) != nil && !azureKey.isEmpty)
    }
    let live = LiveTranscript()
    @Published var liveEnabled = UserDefaults.standard.object(forKey: "liveTranscriptEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveEnabled, forKey: "liveTranscriptEnabled") }
    }
    private let transcriber = Transcription()
    @Published private(set) var permissionIssue: CapturePermission?
    private var prompted = Set<CapturePermission>()
    private let checkPermission: () async -> CapturePermission?
    private let requestPermission: (CapturePermission) -> Void
    private let availableDisplay: () async throws -> SCDisplay

    init(checkPermission: @escaping () async -> CapturePermission? = CapturePermission.missing,
         requestPermission: @escaping (CapturePermission) -> Void = { $0.request() },
         availableDisplay: @escaping () async throws -> SCDisplay = Capture.availableDisplay) {
        self.checkPermission = checkPermission
        self.requestPermission = requestPermission
        self.availableDisplay = availableDisplay
    }

    private var quitting = false
    private var capture: Capture?
    private var transition: Task<Void, Never>?
    private var stopRequested = false

    func start() {
        guard phase == .ready else { return }
        phase = .checking
        permissionIssue = nil
        message = nil
        meters = [:]
        stopRequested = false
        transition = Task {
            do {
                let missing = await checkPermission()
                guard !Task.isCancelled else { return }
                if let missing {
                    permissionIssue = missing
                    phase = .ready
                    if prompted.insert(missing).inserted { requestPermission(missing) }
                    return
                }
                let display = try await availableDisplay()
                guard !Task.isCancelled else { return }
                phase = .starting
                let folder = try MeetingFiles.newFolder()
                let session = Capture(folder: folder, meter: { [weak self] track, peak in
                    Task { @MainActor in self?.meters[track] = Reading(level: peak, date: Date()) }
                }, interrupted: { [weak self] in Task { @MainActor in self?.stop() } })
                capture = session
                started = Date()
                try await session.start(display: display)
                phase = .recording
                if stopRequested {
                    await finish()
                } else if liveEnabled {
                    live.start(folder: folder) { await session.writtenFrames() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                let issue = CapturePermission.from(error)
                if capture != nil { await finish(transcribe: false) }
                permissionIssue = issue
                message = issue == nil ? error.localizedDescription : nil
                phase = .ready
                started = nil
            }
        }
    }

    func togglePause() {
        guard let capture else { return }
        let now = Date()
        if phase == .recording {
            capture.setPaused(true)
            pausedAt = now
            meters = [:]
            phase = .paused
        } else if phase == .paused, let pausedAt, let started {
            capture.setPaused(false)
            self.started = started.addingTimeInterval(now.timeIntervalSince(pausedAt))
            self.pausedAt = nil
            phase = .recording
        }
    }

    func stop() {
        if phase == .checking {
            // ScreenCaptureKit may return after the person has cancelled or quit.
            // Drop this attempt immediately and ignore its eventual result.
            transition?.cancel()
            transition = nil
            phase = .ready
            return
        }
        if phase == .starting { stopRequested = true; return }
        guard phase == .recording || phase == .paused else { return }
        phase = .stopping
        transition = Task { await finish() }
    }

    private func finish(transcribe: Bool = true) async {
        phase = .stopping
        live.cancel()
        if let capture {
            message = await capture.stop()
            if FileManager.default.fileExists(atPath: capture.folder.path) { lastFolder = capture.folder }
        }
        await live.finish()
        let folder = capture?.folder
        capture = nil
        pausedAt = nil
        meters = [:]
        phase = .ready
        started = nil
        if transcribe, !quitting, let folder {
            await writeTranscript(in: folder, recordingNotice: message)
        }
    }

    private func writeTranscript(in folder: URL, recordingNotice: String? = nil) async {
        guard !quitting else { phase = .ready; return }
        phase = .transcribing
        permissionIssue = nil
        lastFolder = folder
        message = recordingNotice
        transcriptFile = nil
        transcriptionStatus = mode == .local ? "Klargør lokal transskription …" : "Klargør lyd til Azure …"
        if mode == .azure { UserDefaults.standard.set(azureResource, forKey: "azureSpeechResource") }
        do {
            try await transcriber.run(folder: folder, mode: mode, resource: azureResource, key: azureKey) {
                self.transcriptionStatus = $0
            }
            transcriptFile = folder.appendingPathComponent(mode.filename)
        } catch { message = [recordingNotice, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
        phase = .ready
    }

    func importAudio() {
        guard phase == .ready, configured else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Importer"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        message = nil
        permissionIssue = nil
        phase = .importing
        transition = Task {
            do {
                let folder = try MeetingFiles.newFolder(title: file.deletingPathExtension().lastPathComponent)
                try await MeetingFiles.importAudio(file, to: folder)
                await writeTranscript(in: folder)
            } catch {
                message = error.localizedDescription
                phase = .ready
            }
        }
    }

    func selectRecording() {
        guard phase == .ready else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Transskriber"
        panel.message = "Vælg mødemappen med lydsporene."
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
        if phase == .importing { transition?.cancel() }
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
    @State private var review: MeetingSelection?
    var body: some View {
        let phase = recorder.phase
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Circle().fill(phase == .recording ? Color.red : .secondary).frame(width: 9, height: 9)
                Text(status).font(.title2.bold())
                Spacer()
                if let started = recorder.started {
                    TimelineView(.periodic(from: started, by: 1)) { time in
                        let seconds = max(0, Int((recorder.pausedAt ?? time.date).timeIntervalSince(started)))
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
            if phase == .ready {
                Toggle("Vis live-transskription på denne Mac", isOn: $recorder.liveEnabled)
                Picker("Efter mødet", selection: $recorder.mode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented)
                if recorder.mode == .azure {
                    TextField("Azure Speech-ressourcens navn", text: $recorder.azureResource)
                    SecureField("Azure Speech-nøgle", text: $recorder.azureKey)
                    Text("Begge lydspor sendes til din Azure-ressource. Azure kan opkræve betaling. Nøglen bruges kun, mens appen er åben.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if recorder.liveEnabled && (phase == .recording || phase == .paused) {
                LiveTranscriptView(preview: recorder.live, paused: phase == .paused)
            }
            if phase == .transcribing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(recorder.transcriptionStatus).lineLimit(2)
                    Spacer()
                    Button("Annuller") { recorder.cancelTranscription() }
                }
            }
            if let issue = recorder.permissionIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Meeting Recorder mangler adgang til " + issue.title.lowercased(), systemImage: "lock")
                    Text("Tillad denne kopi i Systemindstillinger, og tryk Start igen. Er adgangen allerede slået til, så afslut appen med ⌘Q og åbn den igen fra Programmer.")
                    Text(Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Åbn indstillinger") { NSWorkspace.shared.open(issue.settings) }
                        Button("Vis app i Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let message = recorder.message {
                Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
            }
            HStack {
                Button {
                    if phase == .ready { recorder.start() } else { recorder.stop() }
                } label: {
                    Label(phase == .checking ? "Annuller" : (phase == .recording || phase == .paused || phase == .stopping ? "Stop optagelse" : "Start optagelse"),
                          systemImage: phase == .checking ? "xmark" : (phase == .recording || phase == .paused || phase == .stopping ? "stop.fill" : "record.circle"))
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled((phase != .ready && phase != .recording && phase != .paused && phase != .checking) || (phase == .ready && !recorder.configured))
                if phase == .recording || phase == .paused {
                    Button(phase == .paused ? "Genoptag" : "Pause") { recorder.togglePause() }
                }
                Spacer()
                if let folder = recorder.lastFolder {
                    Button("Vis seneste optagelse") { NSWorkspace.shared.open(folder) }
                }
            }
            if phase == .ready {
                HStack {
                    Button("Åbn møde…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.directoryURL = MeetingFiles.root
                        if panel.runModal() == .OK, let url = panel.url { review = MeetingSelection(folder: url) }
                    }
                    Button("Importer lyd…") { recorder.importAudio() }.disabled(!recorder.configured)
                }
                HStack {
                    Button("Transskriber tidligere optagelse…") { recorder.selectRecording() }.disabled(!recorder.configured)
                    Spacer()
                    if let file = recorder.transcriptFile,
                       FileManager.default.fileExists(atPath: file.path) {
                        Button("Åbn transskription") { review = MeetingSelection(folder: file.deletingLastPathComponent(), preferred: file.lastPathComponent) }
                    }
                }
            }
        }
        .padding(24).frame(minWidth: 445, idealWidth: 480)
        .sheet(item: $review) { MeetingReview(selection: $0) }
    }
    private var status: String {
        switch recorder.phase {
        case .ready: return "Klar til optagelse"
        case .checking: return "Kontrollerer adgang…"
        case .starting: return "Starter optagelse…"
        case .recording: return "Optager"
        case .paused: return "På pause"
        case .importing: return "Importerer lyd…"
        case .stopping: return "Gemmer optagelse…"
        case .transcribing: return "Transskriberer"
        }
    }
}

#if !PERMISSION_TEST
@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Meeting Recorder", id: "recorder") {
            RecorderView(recorder: delegate.recorder)
        }.windowResizability(.contentSize)
    }
}
#endif
