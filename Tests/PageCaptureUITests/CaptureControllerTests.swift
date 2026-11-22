import AppKit
import Network
import WebKit
import XCTest
@testable import PageCaptureCore
@testable import PageCaptureUI

/// The document flow through the controller (SPEC "Documents"): pick, download, save panel, export,
/// message, with the save panel and the message replaced.
@MainActor
final class CaptureControllerTests: XCTestCase {
    private var folder: URL!
    private var controller: CaptureController!
    private var window: NSWindow!
    private var requests: [CaptureController.SaveRequest] = []
    private var formats: Set<ExportFormat> = []
    private var messages: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DocumentProtocol.referers = []
        controller = CaptureController(dataStore: .nonPersistent(), defaults: UserDefaults(suiteName: "CaptureControllerTests")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocumentProtocol.self]
        controller.documentSessionConfiguration = configuration
        // On screen, or the page's timers are throttled and a capture never ends.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.webView
        window.orderFrontRegardless()
        requests = []
        messages = []
        controller.savePanelOverride = { [unowned self] request in
            requests.append(request)
            return CaptureController.SaveChoice(folder: folder.appendingPathComponent(request.name), formats: formats)
        }
        controller.messageOverride = { [unowned self] alert in
            messages.append("\(alert.messageText) \(alert.informativeText)")
        }
    }

    override func tearDown() async throws {
        window?.close()
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: "CaptureControllerTests")
    }

    /// The page is a PDF by its MIME type only (its URL has no extension; a loopback server sends
    /// it, as WebKit asks no response policy for loaded data): Return picks it as a document, which
    /// is downloaded with the page as referer and saved unchanged.
    func testPageThatIsAPDFByItsMIMETypeIsSavedAsTheDocument() async throws {
        let server = try await PDFServer.start()
        defer { server.stop() }
        let url = server.url(path: "/report")
        controller.webView.load(URLRequest(url: url))
        try await waitUntil("PDF loaded") { !self.controller.webView.isLoading && self.controller.webView.url == url }
        formats = [.original]

        controller.send(.shortcut)
        controller.send(.returnKey)
        XCTAssertEqual(controller.machine.phase, .downloadingDocument(DocumentSource(url: url, kind: .pdf)))
        XCTAssertEqual(controller.bannerText, "Downloading document…")
        try await waitUntil("saved") { !self.messages.isEmpty }

        XCTAssertEqual(requests.map(\.kind), [.document])
        XCTAssertEqual(requests.first?.name, "report")
        XCTAssertEqual(requests.first?.original, .pdf)
        let saved = folder.appendingPathComponent("report/report.pdf")
        XCTAssertEqual(try Data(contentsOf: saved), PDFServer.pdf)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.deletingLastPathComponent().path), ["report.pdf"])
        XCTAssertEqual(server.referers.last, url.absoluteString, "the download's referer")
        XCTAssertTrue(messages[0].hasPrefix("Document saved Saved to "), messages[0])
        XCTAssertEqual(controller.machine.phase, .idle)
    }

    /// The original answers 404: the page is captured instead, and the message says why.
    func testDocumentThatCannotBeDownloadedIsCapturedAsAPageWithTheReason() async throws {
        let url = URL(string: "https://documents.test/missing.pdf")!
        controller.webView.loadHTMLString("<title>Fallback</title><h1>Fallback page</h1>", baseURL: url)
        try await waitUntil("page loaded") { !self.controller.webView.isLoading && self.controller.webView.url == url }
        formats = [.markdown]

        controller.send(.shortcut)
        controller.send(.returnKey)
        XCTAssertEqual(controller.machine.phase, .downloadingDocument(DocumentSource(url: url, kind: .pdf)))
        try await waitUntil("saved", timeout: 30) { !self.messages.isEmpty }

        XCTAssertEqual(requests.map(\.kind), [.page])
        XCTAssertTrue(messages[0].hasPrefix("Capture saved"), messages[0])
        XCTAssertTrue(messages[0].contains("the document could not be downloaded (HTTP 404), so the frame was captured as a page"),
                      messages[0])
        let markdown = try String(contentsOf: folder.appendingPathComponent("Fallback/Fallback.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Fallback page"), markdown)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(what)")
        throw CancellationError()
    }
}

/// Serves a small PDF as `application/pdf` at any path of `http://127.0.0.1:<port>`, one request
/// per connection, and records the requests' referers.
private final class PDFServer: @unchecked Sendable {
    static let pdf = Data("%PDF-1.4\n% test document\n%%EOF\n".utf8)
    private let listener: NWListener
    private let lock = NSLock()
    private var seen: [String] = []

    var referers: [String] { lock.withLock { seen } }

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> PDFServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = PDFServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        let started = AsyncStream<Bool> { continuation in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(true)
                case .failed, .cancelled: continuation.yield(false)
                default: break
                }
            }
        }
        server.listener.start(queue: .global())
        for await ready in started {
            guard ready else { throw URLError(.cannotConnectToHost) }
            break
        }
        return server
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let referer = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("referer:") }
                .map { $0.dropFirst("referer:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            lock.withLock { seen.append(referer) }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: \(Self.pdf.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + Self.pdf, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Serves `https://documents.test/…`: `missing*` → 404, anything else → a small PDF. Records the referers.
final class DocumentProtocol: URLProtocol {
    nonisolated(unsafe) static var referers: [String] = []
    static let pdf = Data("%PDF-1.4\n% test document\n%%EOF\n".utf8)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "documents.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.referers.append(request.value(forHTTPHeaderField: "Referer") ?? "")
        let missing = url.lastPathComponent.hasPrefix("missing")
        let response = HTTPURLResponse(url: url, statusCode: missing ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": missing ? "text/plain" : "application/pdf"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: missing ? Data("nope".utf8) : Self.pdf)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
