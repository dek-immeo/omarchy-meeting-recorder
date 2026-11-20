import Foundation

@MainActor
final class Transcription {
    private var process: Process?

    func cancel() {
        if let process, process.isRunning { process.terminate() }
    }

    func run(folder: URL, status: (String) -> Void) async throws {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let child = Process()
        child.executableURL = contents.appendingPathComponent("Helpers/meeting-transcriber")
        child.arguments = [folder.path, support.appendingPathComponent("Meeting Recorder/Models").path]
        var env = ProcessInfo.processInfo.environment
        env["ORT_DYLIB_PATH"] = contents.appendingPathComponent("Frameworks/libonnxruntime.dylib").path
        child.environment = env
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        process = child
        defer {
            process = nil
            try? pipe.fileHandleForReading.close()
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
