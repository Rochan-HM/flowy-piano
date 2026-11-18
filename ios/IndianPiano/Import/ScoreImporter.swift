import Foundation
import UniformTypeIdentifiers

/// What the user handed us to turn into a score.
///
/// Score files are parsed on the device. Photos and PDFs of printed music go through the
/// recognition server first (`RecognitionClient`), which returns MusicXML that is imported here
/// as a file. Other sources (e.g. audio transcription) plug in the same way.
enum ScoreImportInput: Sendable {
    case file(URL)
}

/// One way of turning an input into a `Score`. Register new importers in
/// `ScoreImportService.shared`; the file picker's allowed types come from the registry.
protocol ScoreImporter: Sendable {
    var name: String { get }
    var contentTypes: [UTType] { get }
    var fileExtensions: Set<String> { get }
    func canImport(_ input: ScoreImportInput) -> Bool
    func importScore(from input: ScoreImportInput) async throws -> Score
}

extension ScoreImporter {
    func canImport(_ input: ScoreImportInput) -> Bool {
        switch input {
        case .file(let url): return fileExtensions.contains(url.pathExtension.lowercased())
        }
    }
}

enum ScoreImportError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case unreadable(String)
    case invalidFormat(String)
    case noNotes

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext): return "Files of type “\(ext)” aren't supported yet. Use MusicXML (.musicxml, .xml, .mxl) or MIDI (.mid, .midi)."
        case .unreadable(let reason): return "Couldn't read the file: \(reason)"
        case .invalidFormat(let reason): return "The file doesn't look like a valid score: \(reason)"
        case .noNotes: return "The score doesn't contain any playable notes."
        }
    }
}

extension UTType {
    static let musicXML = UTType(importedAs: "com.recordare.musicxml.uncompressed", conformingTo: .xml)
    static let compressedMusicXML = UTType(importedAs: "com.recordare.musicxml", conformingTo: .data)
}

struct ScoreImportService: Sendable {
    static let shared = ScoreImportService(importers: [MusicXMLImporter(), MIDIImporter()])

    let importers: [ScoreImporter]

    var allowedContentTypes: [UTType] {
        var seen = Set<UTType>()
        return importers.flatMap(\.contentTypes).filter { seen.insert($0).inserted }
    }

    var supportedExtensions: Set<String> { importers.reduce(into: []) { $0.formUnion($1.fileExtensions) } }

    func importer(for input: ScoreImportInput) -> ScoreImporter? {
        importers.first { $0.canImport(input) }
    }

    func importScore(from input: ScoreImportInput) async throws -> Score {
        guard let importer = importer(for: input) else {
            switch input {
            case .file(let url): throw ScoreImportError.unsupportedFile(url.pathExtension)
            }
        }
        return try await importer.importScore(from: input)
    }

    func importScore(at url: URL) async throws -> Score {
        try await importScore(from: .file(url))
    }
}

extension ScoreImportInput {
    func readData() throws -> Data {
        switch self {
        case .file(let url):
            do { return try Data(contentsOf: url) } catch { throw ScoreImportError.unreadable(error.localizedDescription) }
        }
    }

    /// Title to use when the score has none, e.g. "la-candeur.pdf" → "La candeur".
    var displayName: String {
        switch self {
        case .file(let url):
            let words = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .joined(separator: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}
