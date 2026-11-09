import Foundation
import Observation

struct SongEntry: Identifiable, Hashable, Codable {
    enum Origin: Hashable, Codable {
        case bundled(resource: String, fileExtension: String)
        case imported(fileName: String)
    }

    var id: String
    var title: String
    var subtitle: String
    var origin: Origin
    /// Things the learner should know about this score, e.g. recognition warnings.
    var notes: [String]?

    var isBundled: Bool {
        if case .bundled = origin { return true }
        return false
    }
}

/// Bundled sample songs plus scores the user imported (copied into Documents/Imported).
@MainActor
@Observable
final class SongLibrary {
    static let bundledSongs: [SongEntry] = [
        SongEntry(id: "twinkle", title: "Twinkle, Twinkle, Little Star",
                  subtitle: "Traditional · both hands · fingering",
                  origin: .bundled(resource: "twinkle-twinkle", fileExtension: "musicxml")),
        SongEntry(id: "ode-to-joy", title: "Ode to Joy",
                  subtitle: "Beethoven · right hand · fingering",
                  origin: .bundled(resource: "ode-to-joy", fileExtension: "musicxml")),
        SongEntry(id: "minuet-in-g", title: "Minuet in G (simplified)",
                  subtitle: "Petzold · both hands · fingering",
                  origin: .bundled(resource: "minuet-in-g", fileExtension: "musicxml")),
    ]

    private(set) var imported: [SongEntry] = []
    var bundled: [SongEntry] { Self.bundledSongs }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let importService: ScoreImportService

    init(directory: URL? = nil, importService: ScoreImportService = .shared) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? documents.appendingPathComponent("Imported", isDirectory: true)
        self.importService = importService
        loadIndex()
    }

    func entry(id: String) -> SongEntry? {
        (bundled + imported).first { $0.id == id }
    }

    func url(for entry: SongEntry) -> URL? {
        switch entry.origin {
        case let .bundled(resource, fileExtension):
            return Bundle.main.url(forResource: resource, withExtension: fileExtension)
        case let .imported(fileName):
            return directory.appendingPathComponent(fileName)
        }
    }

    func loadScore(_ entry: SongEntry) async throws -> Score {
        guard let url = url(for: entry) else { throw ScoreImportError.unreadable("the song file is missing") }
        return try await importService.importScore(at: url)
    }

    /// Copies a user-picked file into the app, validates it by parsing, and adds it to the library.
    func importFile(at source: URL, sourceLabel: String? = nil, notes: [String] = []) async throws -> SongEntry {
        guard importService.importer(for: .file(source)) != nil else {
            throw ScoreImportError.unsupportedFile(source.pathExtension)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)"
        let destination = directory.appendingPathComponent(fileName)
        try await Task.detached(priority: .userInitiated) {
            try Self.coordinatedCopy(from: source, to: destination)
        }.value

        do {
            let score = try await importService.importScore(at: destination)
            let entry = SongEntry(id: "imported-\(fileName)", title: score.title,
                                  subtitle: Self.describe(score, sourceLabel: sourceLabel), origin: .imported(fileName: fileName),
                                  notes: notes.isEmpty ? nil : notes)
            imported.insert(entry, at: 0)
            saveIndex()
            return entry
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func delete(_ entry: SongEntry) {
        guard case let .imported(fileName) = entry.origin else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        imported.removeAll { $0.id == entry.id }
        saveIndex()
    }

    /// Copies a picked file, downloading it first if it lives in a cloud provider.
    nonisolated private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
            do { try FileManager.default.copyItem(at: readableURL, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError {
            throw ScoreImportError.unreadable("“\(source.lastPathComponent)” couldn't be copied into the app (\(error.localizedDescription))")
        }
    }

    static func describe(_ score: Score, sourceLabel: String? = nil) -> String {
        let hands: String
        switch (score.hands.contains(.right), score.hands.contains(.left)) {
        case (true, true): hands = "both hands"
        case (false, true): hands = "left hand"
        default: hands = "right hand"
        }
        var parts = [sourceLabel ?? score.sourceFormat, hands]
        if score.hasFingerings { parts.append("fingering") }
        return parts.joined(separator: " · ")
    }

    private var indexURL: URL { directory.appendingPathComponent("library.json") }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([SongEntry].self, from: data) else { return }
        imported = entries.filter { entry in
            guard case let .imported(fileName) = entry.origin else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(imported) { try? data.write(to: indexURL, options: .atomic) }
    }
}
