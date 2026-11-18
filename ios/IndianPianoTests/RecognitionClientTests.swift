import XCTest
@testable import IndianPiano

/// Exercises `RecognitionClient` against a stubbed server that follows the OMR server contract.
final class RecognitionClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        session = URLSession(configuration: configuration)
        StubServer.reset()
    }

    private func client(token: String = "secret") throws -> RecognitionClient {
        try RecognitionClient(serverURL: "http://omr.test:8000/", token: token, session: session)
    }

    private static func job(_ status: String, done: Int = 0, total: Int = 1, warnings: String = "[]", error: String = "null") -> Data {
        Data("""
        {"id": "job1", "status": "\(status)", "progress": {"pages_done": \(done), "pages_total": \(total)},
         "result": {"title": null, "part_count": 1}, "warnings": \(warnings), "error": \(error),
         "musicxml_url": "/v1/jobs/job1/musicxml", "engine": {"name": "homr", "version": "0.7.0"}}
        """.utf8)
    }

    private var twinkleXML: Data {
        get throws { try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "twinkle-twinkle", withExtension: "musicxml"))) }
    }

    func testUploadsPollsAndDownloadsTheScore() async throws {
        let xml = try twinkleXML
        StubServer.handler = { request, body in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/v1/jobs"):
                return (202, Self.job("running"))
            case ("GET", "/v1/jobs/job1"):
                let warnings = #"[{"code": "fingering_not_recognized", "message": "finger numbers are not read"}, {"code": "rhythm_suspect_measures", "message": "check", "measures": [3, 7]}]"#
                return (200, Self.job("succeeded", done: 1, warnings: warnings))
            case ("GET", "/v1/jobs/job1/musicxml"):
                return (200, xml)
            default:
                return (404, Data(#"{"error": {"code": "job_not_found", "message": "no"}}"#.utf8))
            }
        }

        let page = RecognitionUpload(filename: "page 1.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0x01]))
        let result = try await client().recognize([page])

        XCTAssertEqual(result.musicXML, xml)
        XCTAssertEqual(result.warnings.map(\.code), ["fingering_not_recognized", "rhythm_suspect_measures"])
        XCTAssertEqual(result.warnings[1].userMessage, "Check the rhythm in bars 3, 7.")
        XCTAssertTrue(result.warnings[0].userMessage.contains("Finger numbers"))
        XCTAssertEqual(result.engine, "homr 0.7.0")

        let requests = StubServer.requests
        XCTAssertEqual(requests.map { "\($0.request.httpMethod!) \($0.request.url!.path)" },
                       ["POST /v1/jobs", "GET /v1/jobs/job1", "GET /v1/jobs/job1/musicxml"])
        XCTAssertTrue(requests.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        XCTAssertEqual(requests[0].request.url?.query, "wait=30")
        XCTAssertEqual(requests[1].request.url?.query, "wait=30")
        let contentType = try XCTUnwrap(requests[0].request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: requests[0].body, as: UTF8.self)
        XCTAssertTrue(body.contains(#"Content-Disposition: form-data; name="file"; filename="page 1.jpg""#))
        XCTAssertTrue(body.contains("Content-Type: image/jpeg"))

        let score = try MusicXMLParser.parse(result.musicXML)
        XCTAssertEqual(score.hands, [.right, .left])
    }

    func testSeveralPagesAreSentInOrderAsRepeatedFileFields() throws {
        let pages = (1...3).map { RecognitionUpload(filename: "p\($0).jpg", mimeType: "image/jpeg", data: Data("page\($0)".utf8)) }
        let body = String(decoding: RecognitionClient.multipartBody(pages, boundary: "B"), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: #"name="file""#).count - 1, 3)
        let order = ["page1", "page2", "page3"].map { body.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testRejectedTokenIsReportedClearly() async throws {
        StubServer.handler = { _, _ in (401, Data(#"{"error": {"code": "unauthorized", "message": "missing or invalid bearer token"}}"#.utf8)) }
        do {
            _ = try await client(token: "wrong").recognize([RecognitionUpload(filename: "a.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8))])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RecognitionError, .unauthorized)
        }
    }

    func testServerErrorsUseFriendlyMessages() async throws {
        StubServer.handler = { _, _ in (415, Data(#"{"error": {"code": "unsupported_type", "message": "image/gif is not supported"}}"#.utf8)) }
        do {
            _ = try await client().recognize([RecognitionUpload(filename: "a.gif", mimeType: "image/gif", data: Data([1]))])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RecognitionError, .server(status: 415, code: "unsupported_type", message: "image/gif is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("PDF, JPEG, PNG"))
        }
    }

    func testFailedJobShowsTheServerMessage() async throws {
        StubServer.handler = { _, _ in
            (200, Self.job("failed", error: #"{"code": "recognition_failed", "message": "no page contained music"}"#))
        }
        do {
            _ = try await client().recognize([RecognitionUpload(filename: "a.jpg", mimeType: "image/jpeg", data: Data([1]))])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RecognitionError, .recognitionFailed("no page contained music"))
        }
    }

    func testHealthCheckNeedsNoToken() async throws {
        StubServer.handler = { request, _ in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(#"{"status": "ok", "engine": {"name": "homr", "version": "0.7.0", "reads_fingering": false}}"#.utf8))
        }
        let health = try await client().health()
        XCTAssertEqual(health.engine.name, "homr")
        XCTAssertEqual(StubServer.requests.first?.request.url?.path, "/healthz")
    }

    func testServerURLValidation() {
        XCTAssertThrowsError(try RecognitionClient(serverURL: "omr.local", token: "t")) { error in
            XCTAssertEqual(error as? RecognitionError, .invalidServerURL)
        }
        XCTAssertNoThrow(try RecognitionClient(serverURL: " https://omr.example.com/base ", token: "t"))
    }

    func testLargePhotosAreDownscaledToJPEG() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 6000, height: 3000), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 6000, height: 3000))
        }
        let upload = RecognitionPages.upload(for: big, name: "page")
        XCTAssertEqual(upload.mimeType, "image/jpeg")
        XCTAssertEqual(upload.filename, "page.jpg")
        let decoded = try XCTUnwrap(UIImage(data: upload.data))
        XCTAssertEqual(decoded.size.width * decoded.scale, 4000, accuracy: 1)
        XCTAssertEqual(decoded.size.height * decoded.scale, 2000, accuracy: 1)
    }
}

/// In-process fake HTTP server for `URLSession`.
final class StubServer: URLProtocol {
    struct Recorded {
        var request: URLRequest
        var body: Data
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [Recorded] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.lock.lock()
        Self.requests.append(Recorded(request: request, body: body))
        let handler = Self.handler
        Self.lock.unlock()
        let (status, data) = handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
