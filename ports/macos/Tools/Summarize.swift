import Foundation

@main
enum Summarize {
    static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let summary = try await MeetingSummary.generate(String(contentsOf: input, encoding: .utf8))
            try summary.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
