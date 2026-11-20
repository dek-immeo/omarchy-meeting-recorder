import Darwin
import SwiftUI

struct LiveLine: Decodable, Identifiable, Equatable {
    let source: String
    let ms: Int64
    let text: String
    var id: String { "\(source)-\(ms)" }
}

@MainActor
final class LiveTranscript: ObservableObject {
    @Published private(set) var lines: [LiveLine] = []
    @Published private(set) var partials: [String: LiveLine] = [:]
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private var child: Process?

    func start(folder: URL, process: Process = TranscriptionWorker.process(), cache: URL? = nil,
               azure: AzureLiveSettings? = nil, resumeFrom: [Int64]? = nil,
               frames: @escaping () async -> [Int64]) {
        guard task == nil || resumeFrom != nil else { return }
        let previous = task
        if resumeFrom == nil { lines = [] }
        partials = [:]
        status = azure == nil ? "Klargør lokal sprogmodel …" : "Klargør Azure Speech …"
        task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                try await run(process, folder: folder, cache: cache, azure: azure, start: resumeFrom ?? [0, 0], frames: frames)
            } catch {
                if !Task.isCancelled {
                    partials = [:]
                    status = "Live-tekst er utilgængelig. Optagelsen fortsætter. " + error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        partials = [:]
        task?.cancel()
        if let child, child.isRunning { child.terminate() }
    }

    func finish(keepingLines: Bool = false) async {
        await task?.value
        task = nil
        partials = [:]
        if !keepingLines { lines = [] }
        status = ""
    }

    private func run(_ process: Process, folder: URL, cache: URL?, azure: AzureLiveSettings?,
                     start: [Int64], frames: () async -> [Int64]) async throws {
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        // An exited preview worker must never deliver SIGPIPE to the recorder.
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw RecorderError("Kunne ikke åbne forbindelsen til sprogmodellen.")
        }
        if azure != nil {
            process.arguments = ["--azure-live", folder.path]
        } else {
            let models = try cache ?? TranscriptionWorker.modelCache()
            process.arguments = ["--live", folder.path, models.path]
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
        defer { child = nil }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        var failure: Error?
        do {
            if let azure {
                struct Setup: Encodable { let connection: AzureLiveSettings; let start: [Int64] }
                var setup = try JSONEncoder().encode(Setup(connection: azure, start: start))
                setup.append(10)
                try writer.write(contentsOf: setup)
            }
            for try await line in output.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                if line == "LIVE_READY" || line == "LIVE_NEXT" || line == "LIVE_WAIT" {
                    if line == "LIVE_READY" { status = "Lytter …" }
                    if line == "LIVE_WAIT" { try await Task.sleep(nanoseconds: 500_000_000) }
                    let counts = await frames()
                    try Task.checkCancellation()
                    var data = try JSONEncoder().encode(counts)
                    data.append(10)
                    try writer.write(contentsOf: data)
                } else if line.hasPrefix("LIVE_PARTIAL ") {
                    let row = try JSONDecoder().decode(LiveLine.self, from: Data(line.dropFirst("LIVE_PARTIAL ".count).utf8))
                    partials[row.source] = row.text.isEmpty ? nil : row
                    status = ""
                } else if line.hasPrefix("LIVE_LINE ") {
                    let row = try JSONDecoder().decode(LiveLine.self, from: Data(line.dropFirst("LIVE_LINE ".count).utf8))
                    partials[row.source] = nil
                    guard !row.text.isEmpty else { continue }
                    if let last = lines.last, (row.ms, row.source) < (last.ms, last.source) {
                        let previous = lines.lastIndex { ($0.ms, $0.source) <= (row.ms, row.source) }
                        lines.insert(row, at: previous.map { $0 + 1 } ?? 0)
                    } else {
                        lines.append(row)
                    }
                    status = ""
                } else if line.hasPrefix("Henter ") {
                    status = line
                } else if line.hasPrefix("LIVE_ERROR ") {
                    throw RecorderError(String(line.dropFirst("LIVE_ERROR ".count)))
                }
            }
        } catch { failure = error }
        try? writer.close()
        if process.isRunning { process.terminate() }
        await Task.detached { process.waitUntilExit() }.value
        try? output.fileHandleForReading.close()
        if let failure { throw failure }
        if !Task.isCancelled { throw RecorderError("Den lokale sprogmodel stoppede.") }
    }
}

// Observe user scrolling on this transcript, independently of programmatic scrollTo.
private struct TranscriptScrollObserver: NSViewRepresentable {
    let moved: (Bool) -> Void

    final class Marker: NSView {
        var moved: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if window != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                    name: NSScrollView.didLiveScrollNotification, object: nil)
            }
        }
        @objc private func scrolled(_ event: Notification) {
            guard let scroll = event.object as? NSScrollView, scroll === enclosingScrollView,
                  let document = scroll.documentView else { return }
            moved?(document.bounds.maxY - scroll.documentVisibleRect.maxY < 12)
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.moved = moved }
}

struct LiveTranscriptView: View {
    @ObservedObject var preview: LiveTranscript
    let paused: Bool
    var finished = false
    @State private var following = true
    @Environment(\.colorScheme) private var scheme
    private var palette: RecorderPalette { RecorderPalette(scheme) }

    var body: some View {
        ScrollViewReader { scroll in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(finished ? "Foreløbig transskription" : "Live-transskription").font(.headline)
                    Spacer()
                    if !following {
                        Button("Til seneste") {
                            following = true
                            scroll.scrollTo("bottom", anchor: .bottom)
                        }.buttonStyle(.link)
                    }
                }
                if paused || !preview.status.isEmpty {
                    Text(paused ? "På pause" : preview.status).font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.lines) { row in line(row, partial: false) }
                        ForEach(preview.partials.values.sorted { ($0.ms, $0.source) < ($1.ms, $1.source) }) { row in
                            line(row, partial: true)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TranscriptScrollObserver { following = $0 })
                }
                .onAppear { if following { scroll.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: preview.lines.count) { _ in if following { scroll.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: preview.partials) { _ in if following { scroll.scrollTo("bottom", anchor: .bottom) } }
            }
        }.padding(14).recorderCard(palette)
    }

    private func line(_ row: LiveLine, partial: Bool) -> some View {
        let seconds = row.ms / 1000
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.source).font(.caption.bold()).foregroundStyle(row.source == "Mikrofon" ? palette.mic : palette.system)
                Text(String(format: "%02lld:%02lld", seconds / 60, seconds % 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(row.text).italic(partial).foregroundStyle(partial ? .secondary : .primary).textSelection(.enabled)
        }
    }
}
