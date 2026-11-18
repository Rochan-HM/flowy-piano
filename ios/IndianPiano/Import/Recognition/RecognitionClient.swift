import Foundation

/// One page (or a whole PDF) to send to the recognition server.
struct RecognitionUpload: Sendable, Equatable {
    var filename: String
    var mimeType: String
    var data: Data
}

struct RecognitionWarning: Sendable, Equatable, Decodable {
    var code: String
    var message: String
    var page: Int?
    var measures: [Int]?
}

struct RecognitionProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case uploading, queued, recognizing, downloading }
    var phase: Phase
    var pagesDone = 0
    var pagesTotal = 0
}

struct RecognitionResult: Sendable {
    var musicXML: Data
    var warnings: [RecognitionWarning]
    var title: String?
    var engine: String?
}

enum RecognitionError: LocalizedError, Equatable {
    case notConfigured
    case invalidServerURL
    case unauthorized
    case server(status: Int, code: String, message: String)
    case recognitionFailed(String)
    case canceled
    case timedOut
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Sheet music recognition is off or has no server set. Turn it on in Settings › Sheet music recognition."
        case .invalidServerURL: return "The recognition server URL isn't valid."
        case .unauthorized: return "The recognition server rejected the access token. Check it in Settings."
        case let .server(_, code, message): return Self.friendly(code: code) ?? message
        case let .recognitionFailed(message): return "No music could be read: \(message)"
        case .canceled: return "Recognition was canceled."
        case .timedOut: return "The recognition server took too long. Try again or with fewer pages."
        case let .unexpectedResponse(detail): return "Unexpected reply from the recognition server (\(detail))."
        }
    }

    private static func friendly(code: String) -> String? {
        switch code {
        case "upload_too_large": return "The upload is too large for the server (20 MB per request by default)."
        case "too_many_pages": return "Too many pages for one import (12 by default)."
        case "image_too_large": return "A photo is too large (over the server's megapixel limit)."
        case "unsupported_type": return "The server can't read this file type. Use a PDF, JPEG, PNG, HEIC, TIFF or WebP."
        case "invalid_pdf": return "The PDF couldn't be opened."
        case "invalid_image": return "An image couldn't be opened."
        case "no_input": return "Nothing was uploaded."
        case "queue_full": return "The recognition server is busy. Try again in a minute."
        default: return nil
        }
    }
}

/// Client for the flowy-piano recognition server (`server/` in the repository):
/// `POST /v1/jobs?wait=30` → long-poll `GET /v1/jobs/{id}?wait=30` → `GET /v1/jobs/{id}/musicxml`.
struct RecognitionClient: Sendable {
    var baseURL: URL
    var token: String
    var session: URLSession = .shared
    /// The server long-polls for up to 30 s, so requests need a longer timeout than that.
    var requestTimeout: TimeInterval = 75
    var overallTimeout: TimeInterval = 15 * 60

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    init(serverURL: String, token: String, session: URLSession = .shared) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw RecognitionError.invalidServerURL
        }
        self.init(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), session: session)
    }

    struct Health: Decodable, Sendable {
        struct Engine: Decodable, Sendable {
            var name: String
            var version: String
        }
        var status: String
        var engine: Engine
    }

    func health() async throws -> Health {
        var request = URLRequest(url: endpoint("healthz"), timeoutInterval: 15)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        return try decode(Health.self, from: data)
    }

    func recognize(_ uploads: [RecognitionUpload],
                   onProgress: @escaping @Sendable (RecognitionProgress) -> Void = { _ in }) async throws -> RecognitionResult {
        guard !uploads.isEmpty else { throw RecognitionError.server(status: 422, code: "no_input", message: "Nothing to upload") }
        let started = Date()
        onProgress(RecognitionProgress(phase: .uploading))

        let boundary = "IndianPiano-\(UUID().uuidString)"
        var request = authorized(URLRequest(url: endpoint("v1/jobs", query: "wait=30"), timeoutInterval: requestTimeout))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(uploads, boundary: boundary)
        var job = try await send(request, as: Job.self)

        do {
            while !job.isFinished {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(started) < overallTimeout else { throw RecognitionError.timedOut }
                onProgress(job.progressSnapshot)
                let poll = authorized(URLRequest(url: endpoint("v1/jobs/\(job.id)", query: "wait=30"), timeoutInterval: requestTimeout))
                job = try await send(poll, as: Job.self)
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                await cancelJob(job.id)
                throw RecognitionError.canceled
            }
            throw error
        }

        switch job.status {
        case "succeeded":
            onProgress(RecognitionProgress(phase: .downloading, pagesDone: job.progress?.pagesDone ?? 0, pagesTotal: job.progress?.pagesTotal ?? 0))
            let path = job.musicxmlURL ?? "/v1/jobs/\(job.id)/musicxml"
            let download = authorized(URLRequest(url: resolve(path), timeoutInterval: requestTimeout))
            let (data, response) = try await session.data(for: download)
            try check(response, data: data)
            return RecognitionResult(musicXML: data, warnings: job.warnings ?? [], title: job.result?.title,
                                     engine: job.engine.map { "\($0.name) \($0.version)" })
        case "canceled":
            throw RecognitionError.canceled
        default:
            throw RecognitionError.recognitionFailed(job.error?.message ?? "the server couldn't read the pages")
        }
    }

    // MARK: - Wire format

    struct Job: Decodable, Sendable {
        struct Progress: Decodable, Sendable {
            var pagesDone: Int
            var pagesTotal: Int
            enum CodingKeys: String, CodingKey {
                case pagesDone = "pages_done"
                case pagesTotal = "pages_total"
            }
        }
        struct Summary: Decodable, Sendable {
            var title: String?
        }
        struct Failure: Decodable, Sendable {
            var code: String
            var message: String
        }
        struct Engine: Decodable, Sendable {
            var name: String
            var version: String
        }

        var id: String
        var status: String
        var progress: Progress?
        var result: Summary?
        var warnings: [RecognitionWarning]?
        var error: Failure?
        var musicxmlURL: String?
        var engine: Engine?

        enum CodingKeys: String, CodingKey {
            case id, status, progress, result, warnings, error, engine
            case musicxmlURL = "musicxml_url"
        }

        var isFinished: Bool { ["succeeded", "failed", "canceled"].contains(status) }

        var progressSnapshot: RecognitionProgress {
            RecognitionProgress(phase: status == "queued" ? .queued : .recognizing,
                                pagesDone: progress?.pagesDone ?? 0, pagesTotal: progress?.pagesTotal ?? 0)
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            var code: String
            var message: String
        }
        var error: Detail
    }

    static func multipartBody(_ uploads: [RecognitionUpload], boundary: String) -> Data {
        var body = Data()
        for upload in uploads {
            let name = upload.filename.replacingOccurrences(of: "\"", with: "'")
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
            body.append(Data("Content-Type: \(upload.mimeType)\r\n\r\n".utf8))
            body.append(upload.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: - Helpers

    private func endpoint(_ path: String, query: String? = nil) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/" + path
        components.query = query
        return components.url!
    }

    private func resolve(_ path: String) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return endpoint(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        return try decode(type, from: data)
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RecognitionError.unexpectedResponse("not HTTP") }
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw RecognitionError.unauthorized }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            throw RecognitionError.server(status: http.statusCode, code: envelope.error.code, message: envelope.error.message)
        }
        throw RecognitionError.server(status: http.statusCode, code: "http_\(http.statusCode)", message: "HTTP \(http.statusCode)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RecognitionError.unexpectedResponse("couldn't read \(T.self)")
        }
    }

    private func cancelJob(_ id: String) async {
        var request = authorized(URLRequest(url: endpoint("v1/jobs/\(id)"), timeoutInterval: 10))
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }
}

extension RecognitionWarning {
    /// What the learner should know, phrased for the app.
    var userMessage: String {
        switch code {
        case "fingering_not_recognized":
            return "Finger numbers printed in the score aren't read from photos or PDFs, so this lesson has none."
        case "low_resolution":
            return pageText + "The image is low resolution. Retake the photo closer for better results."
        case "no_grand_staff", "empty_staff":
            return pageText + "Right and left hands may not be separated correctly."
        case "rhythm_suspect_measures":
            let bars = (measures ?? []).map(String.init).joined(separator: ", ")
            return bars.isEmpty ? "Some bars may have wrong rhythms." : "Check the rhythm in bar\((measures?.count ?? 0) == 1 ? "" : "s") \(bars)."
        case "page_failed", "no_music_found":
            return pageText + "No music was found on this page, so it was skipped."
        default:
            return message
        }
    }

    private var pageText: String { page.map { "Page \($0): " } ?? "" }
}
