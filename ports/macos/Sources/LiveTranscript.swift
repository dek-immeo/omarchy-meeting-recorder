import Darwin
import SwiftUI

struct LiveLine: Decodable, Identifiable {
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

    func finish() async {
        await task?.value
        task = nil
        partials = [:]
        lines = []
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
                    lines.append(row)
                    lines.sort { ($0.ms, $0.source) < ($1.ms, $1.source) }
                    if lines.count > 120 { lines.removeFirst(lines.count - 120) }
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

struct LiveTranscriptView: View {
    @ObservedObject var preview: LiveTranscript
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live-transskription").font(.headline)
            if !preview.status.isEmpty || paused {
                Text(paused ? "På pause" : preview.status).font(.callout).foregroundStyle(.secondary)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.lines) { row in
                            let seconds = Int(row.ms / 1000)
                            VStack(alignment: .leading) {
                                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60) + " · " + row.source)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(row.text).textSelection(.enabled)
                            }.id(row.id)
                        }
                        ForEach(preview.partials.values.sorted { $0.source < $1.source }) { row in
                            Text(row.source + " · " + row.text)
                                .italic().foregroundStyle(.secondary).id("partial-" + row.source)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: preview.partials.keys.sorted()) { sources in
                    if let source = sources.last { scroll.scrollTo("partial-" + source, anchor: .bottom) }
                }
                .onChange(of: preview.lines.last?.id) { id in
                    if let id { scroll.scrollTo(id, anchor: .bottom) }
                }
            }.frame(height: 150)
        }
    }
}
