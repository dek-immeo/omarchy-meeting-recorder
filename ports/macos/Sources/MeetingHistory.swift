import SwiftUI

struct PastMeeting: Identifiable {
    let folder: URL
    let title: String
    let date: Date
    let transcript: String?
    let hasSummary: Bool
    var id: URL { folder }

    static func load(from root: URL) throws -> [Self] {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let folders: [URL]
        do {
            folders = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folders.compactMap { folder -> Self? in
            guard let values = try? folder.resourceValues(forKeys: keys), values.isDirectory == true,
                  let items = try? files.contentsOfDirectory(atPath: folder.path) else { return nil }
            let names = Set(items)
            let variants = TranscriptionMode.allCases.map(\.filename).filter(names.contains)
            guard !variants.isEmpty || !names.isDisjoint(with: ["Import.wav", "Mikrofon.wav", "Systemlyd.wav"]) else { return nil }
            let summarized = variants.first { names.contains(MeetingSummary.filename(for: $0)) }
            let name = folder.lastPathComponent
            let stamp = String(name.prefix(19))
            let recorded = formatter.date(from: stamp)
            let title: String
            if recorded != nil, name.range(of: #" [a-fA-F0-9]{8}$"#, options: .regularExpression) != nil {
                let subject = name.dropFirst(19).dropLast(9).trimmingCharacters(in: .whitespaces)
                title = subject.isEmpty ? "Møde kl. " + String(stamp.suffix(8)).replacingOccurrences(of: ".", with: ":") : subject
            } else {
                title = name
            }
            return Self(folder: folder, title: title, date: recorded ?? values.creationDate ?? values.contentModificationDate ?? .distantPast,
                        transcript: summarized ?? variants.first, hasSummary: summarized != nil)
        }.sorted { ($0.date, $0.folder.path) > ($1.date, $1.folder.path) }
    }
}

struct MeetingHistoryView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    @State private var revision = 0
    @State private var meetings: [PastMeeting] = []
    @State private var query = ""
    @State private var error: String?

    private var days: [[PastMeeting]] {
        let visible = meetings.filter { $0.folder != recorder.activeFolder && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.folder.lastPathComponent.localizedCaseInsensitiveContains(query)) }
        return Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }.map(\.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Søg efter mødetitel eller dato", text: $query).textFieldStyle(.roundedBorder)
            if let error {
                Text(error)
                Button("Prøv igen") { revision += 1 }
            } else if days.isEmpty {
                Text(query.isEmpty ? "Her vises dine gemte optagelser og importerede møder." : "Ingen møder matcher søgningen.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(days, id: \.first?.id) { day in
                        Section(header: Text(day[0].date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))) {
                            ForEach(day) { meeting in
                                Button {
                                    openWindow(id: "meeting-review", value: MeetingSelection(folder: meeting.folder, preferred: meeting.transcript, opensSummary: meeting.hasSummary))
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: meeting.hasSummary ? "note.text" : "waveform")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(meeting.title).font(.headline)
                                            Text(meeting.hasSummary ? "Opsummering og transskription" : meeting.transcript != nil ? "Transskription" : "Lydoptagelse")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(meeting.date, style: .time).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(.vertical, 5).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .padding(18).frame(minWidth: 360, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
        .task(id: revision) {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try PastMeeting.load(from: MeetingFiles.root) }.value
                try Task.checkCancellation()
                meetings = result
                error = nil
            } catch {
                if !Task.isCancelled { self.error = "Mødemappen kunne ikke læses. " + error.localizedDescription }
            }
        }
        .onChange(of: activeState) { if $0 == .key { revision += 1 } }
        .onChange(of: recorder.phase) { if $0 == .ready { revision += 1 } }
    }
}
