import Foundation
import ImageIO

/// Serves image downloads in tests for `pctest://` and `https://images.test/` URLs, and records the
/// requests it saw. Paths: `*/missing.*` → 404, `*/login.*` → an HTML page, `*/noext` → JPEG MIME,
/// `*.css` → `Fixtures/styles/<name>` (empty when there is none), `*.woff2` → a few font bytes,
/// anything else → a 1×1 PNG.
final class FixtureURLProtocol: URLProtocol {
    struct Seen: Sendable {
        var url: URL
        var referer: String?
        var cookie: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [Seen] = []

    static var requests: [Seen] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = [] } }

    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// A 16×16 AVIF made with ImageIO (the system encodes AVIF; it does not encode WebP).
    static let avif: Data = {
        let source = CGImageSourceCreateWithData(png16 as CFData, nil)!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.avif" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, CGImageSourceCreateImageAtIndex(source, 0, nil)!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }()

    /// A 16×16 WebP (`Fixtures/images/pixel.webp`, made with cwebp).
    static let webp = try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/images/pixel.webp", withExtension: nil)!)

    private static let png16 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAABlklEQVR4nBXRURVEIQhFUSMYgQhGMAIRiGCEE8EIRiACEYhABCLMG7/ZrMt1jMEcyGAN9kAHNjgDBnfwBj6IQQ5q0IMxJnMikzXZE53Y5EyY3Mmb+CQmOalJzw8IUxBhCVtQwYQjIFzhCS6EkEIJLR9YzIUs1mIvdGGLs2BxF2/hi1jkoha9PrCZG9mszd7oxjZnw+Zu3sY3sclNbXp/QJmKKEvZiiqmHAXlKk9xJZRUSmn9gDENMZaxDTXMOAbGNZ7hRhhplNH2gcM8yGEd9kEPdjgHDvfwDn6IQx7q0OcD/wK/Sr4jv9hfkG/1N/x/Fx44BCQU9Pc94zIvclmXfdGLXc79j9/Lu/glLnmpS98PPOZDHuuxH/qwx3n/5ffxHv6IRz7q0e8DznTEWc521DHn+D/KdZ7jTjjplNP+gWAGEqxgBxpYcOIf/AYv8CCCDCro+EAyE0lWshNNLDn5P/MmL/Ekkkwq6fxAMQspVrELLaw49S/lFq/wIoosquj6QDMbaVazG22sOf2v8Dav8SaabKrp5geIAnAQEbP2+wAAAABJRU5ErkJggg==")!

    static let font = Data("wOF2fixture".utf8)

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.scheme == "pctest" || url.host == "images.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let cookie = request.value(forHTTPHeaderField: "Cookie")
        Self.lock.withLock {
            Self.seen.append(Seen(url: url, referer: request.value(forHTTPHeaderField: "Referer"), cookie: cookie))
        }
        let name = url.lastPathComponent
        let status: Int
        let mime: String
        let body: Data
        if name.hasPrefix("missing") {
            (status, mime, body) = (404, "text/plain", Data("nope".utf8))
        } else if name.hasPrefix("login") {
            (status, mime, body) = (200, "text/html", Data("<html>sign in</html>".utf8))
        } else if url.pathExtension == "css" {
            let file = Bundle.module.url(forResource: "Fixtures/styles/\(name)", withExtension: nil)
            (status, mime, body) = (200, "text/css", file.flatMap { try? Data(contentsOf: $0) } ?? Data())
        } else if url.pathExtension == "woff2" {
            (status, mime, body) = (200, "font/woff2", Self.font)
        } else if url.pathExtension == "avif" {
            (status, mime, body) = (200, "image/avif", Self.avif)
        } else if url.pathExtension == "webp" {
            (status, mime, body) = (200, "image/webp", Self.webp)
        } else if name == "noext" {
            (status, mime, body) = (200, "image/jpeg", Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]) + Data("JFIF".utf8))
        } else {
            (status, mime, body) = (200, "image/png", Self.png)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
