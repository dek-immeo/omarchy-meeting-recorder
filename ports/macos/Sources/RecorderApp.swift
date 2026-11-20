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
    @Published private(set) var meters: [Track: [Reading]] = [:]

    private func receive(_ peak: Float, from track: Track) {
        guard phase == .starting || phase == .recording else { return }
        var samples = meters[track] ?? []
        let now = Date()
        samples.removeAll { now.timeIntervalSince($0.date) >= Meter.historySeconds }
        samples.append(Reading(level: peak, date: now))
        meters[track] = samples
    }
    @Published private(set) var transcriptionStatus = ""
    @Published var mode = TranscriptionMode.local
    @Published var azureResource = UserDefaults.standard.string(forKey: "azureSpeechResource") ?? ""
    @Published var azureKey = ""
    @Published private(set) var transcriptFile: URL?
    var configured: Bool {
        mode == .local || (azureResource.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"#, options: .regularExpression) != nil && !azureKey.isEmpty)
    }
    let live = LiveTranscript()
    @Published var liveProvider = LiveProvider.local
    @Published var speechEndpoint = UserDefaults.standard.string(forKey: "azureLiveEndpoint") ?? ""
    @Published var speechLanguage = UserDefaults.standard.string(forKey: "azureLiveLanguage") ?? "da-DK"
    var usesAzureLive: Bool { liveEnabled && liveProvider == .azure }
    var liveSettings: AzureLiveSettings? {
        AzureLiveSettings(endpoint: speechEndpoint, key: azureKey, language: speechLanguage)
    }
    var recordingConfigured: Bool { configured && (!usesAzureLive || liveSettings != nil) }
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
    private var pausedFrames: [Int64] = [0, 0]

    func start() {
        guard phase == .ready, recordingConfigured else { return }
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
                    Task { @MainActor in self?.receive(peak, from: track) }
                }, interrupted: { [weak self] in Task { @MainActor in self?.stop() } })
                capture = session
                started = Date()
                try await session.start(display: display)
                phase = .recording
                if stopRequested {
                    await finish()
                } else if liveEnabled {
                    if usesAzureLive {
                        UserDefaults.standard.set(speechEndpoint, forKey: "azureLiveEndpoint")
                        UserDefaults.standard.set(speechLanguage, forKey: "azureLiveLanguage")
                    }
                    live.start(folder: folder, azure: usesAzureLive ? liveSettings : nil) { await session.writtenFrames() }
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
            pausedFrames = capture.setPaused(true)
            if usesAzureLive { live.cancel() }
            pausedAt = now
            phase = .paused
        } else if phase == .paused, let pausedAt, let started {
            capture.setPaused(false)
            self.started = started.addingTimeInterval(now.timeIntervalSince(pausedAt))
            self.pausedAt = nil
            meters = [:]
            phase = .recording
            if usesAzureLive, let settings = liveSettings {
                live.start(folder: capture.folder, azure: settings, resumeFrom: pausedFrames) { await capture.writtenFrames() }
            }
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
    static let historySeconds = 5.0
    let title: String
    let icon: String
    let samples: [Recorder.Reading]
    let date: Date
    let tint: Color

    var body: some View {
        let latest = samples.last.flatMap { date.timeIntervalSince($0.date) < 0.5 ? $0.level : nil } ?? 0
        let level = latest > 0.001 ? String(format: "%.0f dB", 20 * log10(latest)) : "— dB"
        VStack(spacing: 7) {
            HStack {
                Label(title, systemImage: icon).font(.headline)
                Spacer()
                Text(level).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let count = max(1, Int(size.width / 4))
                let step = size.width / CGFloat(count)
                var peaks = [Float](repeating: 0, count: count)
                for sample in samples {
                    let age = date.timeIntervalSince(sample.date)
                    guard age >= 0, age < Self.historySeconds else { continue }
                    let index = count - 1 - Int(age / Self.historySeconds * Double(count))
                    peaks[index] = max(peaks[index], sample.level)
                }
                for (index, peak) in peaks.enumerated() {
                    let db = 20 * log10(max(0.001, Double(peak)))
                    let height = max(2, min(1, (db + 60) / 60) * size.height)
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                      width: step * 0.55, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(tint.opacity(peak > 0 ? 0.85 : 0.4)))
                }
            }
            .frame(height: 35)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecorderView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    @State private var settingsOpen = false
    private var palette: RecorderPalette { RecorderPalette(scheme) }
    private var capturing: Bool { recorder.phase == .recording || recorder.phase == .paused }
    private var processing: Bool { [.stopping, .importing, .transcribing].contains(recorder.phase) }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820 && recorder.phase == .ready
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            ScrollView {
                layout {
                    VStack(alignment: .leading, spacing: 16) {
                        if processing {
                            processingPanel
                        } else {
                            monitor
                            controls
                        }
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        details
                    }.frame(maxWidth: .infinity)
                }
                .padding(geometry.size.width < 420 ? 16 : 24)
                .frame(maxWidth: wide ? 1120 : 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(palette.canvas)
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .frame(minWidth: 360, minHeight: 300)
    }

    @ViewBuilder private var details: some View {
        if capturing && recorder.liveEnabled {
            LiveTranscriptView(preview: recorder.live, paused: recorder.phase == .paused)
        }
        if recorder.phase == .ready {
            settings
            if recorder.mode == .azure {
                Text("Lydsporene sendes til din Azure-ressource. Azure kan opkræve betaling. Nøglen bruges kun, mens appen er åben.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button { openMeeting() } label: { Label("Åbn møde…", systemImage: "folder") }
                Spacer()
                Button { recorder.importAudio() } label: { Label("Importer lyd…", systemImage: "waveform.badge.plus") }
                    .disabled(!recorder.configured)
            }.buttonStyle(.borderless).padding(.horizontal, 6)
        }
        if let issue = recorder.permissionIssue { permissionPanel(issue) }
        if let message = recorder.message {
            Label(message, systemImage: "exclamationmark.triangle")
                .textSelection(.enabled).padding(14).recorderCard(palette)
        }
        if recorder.phase == .ready, let folder = recorder.lastFolder {
            Divider()
            HStack {
                Button("Vis seneste optagelse") { NSWorkspace.shared.open(folder) }
                Spacer()
                if let file = recorder.transcriptFile, FileManager.default.fileExists(atPath: file.path) {
                    Button("Åbn transskription") {
                        showReview(MeetingSelection(folder: file.deletingLastPathComponent(), preferred: file.lastPathComponent))
                    }
                }
            }.buttonStyle(.borderless)
        }
    }

    private func showReview(_ selection: MeetingSelection) {
        openWindow(id: "meeting-review", value: selection)
    }

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(status).font(recorderHeading)
                Spacer()
                if let started = recorder.started {
                    TimelineView(.periodic(from: started, by: 1)) { time in
                        let seconds = max(0, Int((recorder.pausedAt ?? time.date).timeIntervalSince(started)))
                        HStack(spacing: 6) {
                            if recorder.phase == .recording { Circle().fill(.red).frame(width: 7, height: 7) }
                            Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
            TimelineView(.animation(minimumInterval: 0.1, paused: recorder.phase != .recording)) { time in
                let date = recorder.pausedAt ?? time.date
                VStack(spacing: 13) {
                    Meter(title: "Mikrofon", icon: "mic.fill", samples: recorder.meters[.microphone] ?? [], date: date, tint: palette.mic)
                    Divider()
                    Meter(title: "Systemlyd", icon: "speaker.wave.2.fill", samples: recorder.meters[.system] ?? [], date: date, tint: palette.system)
                }
            }
        }.padding(22).recorderCard(palette, monitor: true)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if capturing {
                Button(recorder.phase == .paused ? "Genoptag" : "Pause") { recorder.togglePause() }
                    .controlSize(.large).recorderButtonShape()
            }
            Button {
                if recorder.phase == .ready { recorder.start() } else { recorder.stop() }
            } label: {
                Label(recorder.phase == .checking ? "Annuller" : capturing ? "Stop optagelse" : "Start optagelse",
                      systemImage: recorder.phase == .checking ? "xmark" : capturing ? "stop.fill" : "record.circle")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 29)
            }
            .buttonStyle(.borderedProminent).recorderButtonShape().controlSize(.large)
            .tint(capturing ? .red : palette.accent)
            .disabled(recorder.phase == .starting || (recorder.phase == .ready && !recorder.recordingConfigured))
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { settingsOpen.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Indstillinger").font(.headline)
                        Text(recorder.mode.rawValue).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: settingsOpen ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(settingsOpen ? "Udvidet" : "Skjult")
            if settingsOpen {
                Divider()
                Toggle("Vis live-transskription", isOn: $recorder.liveEnabled)
                if recorder.liveEnabled {
                    Picker("Under mødet", selection: $recorder.liveProvider) {
                        ForEach(LiveProvider.allCases, id: \.self) { provider in Text(provider.rawValue).tag(provider) }
                    }.pickerStyle(.segmented)
                }
                if recorder.usesAzureLive {
                    TextField("Azure Speech-endpoint (https://…)", text: $recorder.speechEndpoint)
                    TextField("Talesprog, fx da-DK", text: $recorder.speechLanguage)
                    Text("Mikrofon og systemlyd streames til Azure som to forbindelser under mødet. Azure kan opkræve betaling for begge.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Efter mødet", selection: $recorder.mode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented)
                if recorder.mode == .azure {
                    TextField("Azure Speech-ressourcens navn", text: $recorder.azureResource)
                }
                if recorder.usesAzureLive || recorder.mode == .azure {
                    SecureField("Azure Speech-nøgle", text: $recorder.azureKey)
                }
                if recorder.usesAzureLive && !recorder.speechEndpoint.isEmpty && !recorder.azureKey.isEmpty && recorder.liveSettings == nil {
                    Text("Kontrollér Speech-endpointet fra Azure-portalen og talesproget (fx da-DK).").font(.callout)
                }
                Button("Transskriber tidligere optagelse…") { recorder.selectRecording() }
                    .disabled(!recorder.configured)
            }
        }.padding(16).recorderCard(palette)
    }

    private var processingPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(status).font(recorderHeading)
            HStack {
                ProgressView().controlSize(.small)
                if recorder.phase == .transcribing {
                    Text(recorder.transcriptionStatus).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Annuller") { recorder.cancelTranscription() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22).recorderCard(palette, monitor: true)
    }

    private func permissionPanel(_ issue: CapturePermission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tillad adgang til " + issue.title.lowercased(), systemImage: "lock").font(.headline)
            Text("Tillad denne kopi i Systemindstillinger, og tryk Start igen. Hvis adgangen allerede er slået til, så afslut med ⌘Q og åbn samme kopi igen.")
            Text(Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
            HStack {
                Button("Åbn indstillinger") { NSWorkspace.shared.open(issue.settings) }
                Button("Vis app i Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
        }.padding(14).recorderCard(palette)
    }

    private func openMeeting() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = MeetingFiles.root
        if panel.runModal() == .OK, let url = panel.url { showReview(MeetingSelection(folder: url)) }
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
        }
        .defaultSize(width: 480, height: 520)
        .windowResizability(.contentMinSize)

        WindowGroup("Mødedetaljer", id: "meeting-review", for: MeetingSelection.self) { $selection in
            if let selection {
                MeetingReview(selection: selection)
                    .navigationTitle(selection.folder.lastPathComponent)
            }
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}
#endif
