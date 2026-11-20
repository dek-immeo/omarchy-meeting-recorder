import Foundation

enum TranscriptionMode: String, CaseIterable {
    case local = "På denne Mac"
    case azure = "Azure Foundry"
    var filename: String { self == .local ? "Transskription.md" : "Transskription-Azure.md" }
}

enum TranscriptionWorker {
    static var contents: URL { Bundle.main.bundleURL.appendingPathComponent("Contents") }

    static func modelCache() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("Meeting Recorder/Models")
    }

    static func process() -> Process {
        let child = Process()
        child.executableURL = contents.appendingPathComponent("Helpers/meeting-transcriber")
        var env = ProcessInfo.processInfo.environment
        env["ORT_DYLIB_PATH"] = contents.appendingPathComponent("Frameworks/libonnxruntime.dylib").path
        child.environment = env
        return child
    }
}

@MainActor
final class Transcription {
    private var process: Process?

    func cancel() {
        if let process, process.isRunning { process.terminate() }
    }

    func run(folder: URL, mode: TranscriptionMode, resource: String, key: String, status: (String) -> Void) async throws {
        let files = FileManager.default
        let child = TranscriptionWorker.process()
        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secret = Pipe()
        if mode == .azure {
            try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            child.arguments = ["--azure", folder.path, scratch.path, resource]
            child.standardInput = secret
        } else {
            child.arguments = [folder.path, try TranscriptionWorker.modelCache().path]
        }
        defer { if mode == .azure { try? files.removeItem(at: scratch) } }
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        process = child
        defer {
            if child.isRunning { child.terminate() }
            process = nil
            try? pipe.fileHandleForReading.close()
        }
        if mode == .azure {
            try secret.fileHandleForReading.close()
            try secret.fileHandleForWriting.write(contentsOf: Data(key.utf8))
            try secret.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.close()
        var lastError: String?
        for try await line in pipe.fileHandleForReading.bytes.lines {
            if line.hasPrefix("Transskriptionen blev afbrudt:") { lastError = line }
            if ["Henter ", "Klargør ", "Finder ", "Transskriberer ·"].contains(where: line.hasPrefix) {
                status(line)
            }
        }
        child.waitUntilExit()
        guard child.terminationStatus == 0 else {
            throw RecorderError(lastError ?? "Transskriptionen blev afbrudt. Optagelsen ligger stadig i mødemappen.")
        }
    }
}
