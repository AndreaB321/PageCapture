// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PageCapture",
    platforms: [.macOS(.v14)],
    products: [
        /// Shipped in `Contents/Helpers`; `DocumentConverter` runs it sandboxed to OCR scanned PDFs.
        .executable(name: "pagecapture-ocr", targets: ["PageCaptureOCR"]),
    ],
    targets: [
        .target(
            name: "PageCaptureCore",
            resources: [
                .copy("Resources/merge.js"), .copy("Resources/capture.js"),
                .copy("Resources/markdown.js"), .copy("Resources/document.js"),
                .copy("Resources/chrome.js"),
            ]
        ),
        /// The app's windows and views; a library so ManualShots can drive them in-process.
        .target(
            name: "PageCaptureUI",
            dependencies: ["PageCaptureCore"]
        ),
        .executableTarget(
            name: "PageCapture",
            dependencies: ["PageCaptureCore", "PageCaptureUI"]
        ),
        /// Takes the manual's screenshots (docs/manual/images) from the real UI. Not shipped.
        .executableTarget(
            name: "ManualShots",
            dependencies: ["PageCaptureCore", "PageCaptureUI"]
        ),
        /// Vision OCR of scanned PDFs. Only the `pagecapture-ocr` helper links it: PDFs are never
        /// decoded in the app's own process.
        .target(name: "PageCaptureOCRKit"),
        .executableTarget(
            name: "PageCaptureOCR",
            dependencies: ["PageCaptureOCRKit"]
        ),
        .testTarget(
            name: "PageCaptureCoreTests",
            dependencies: ["PageCaptureCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PageCaptureOCRKitTests",
            dependencies: ["PageCaptureOCRKit"]
        ),
        .testTarget(
            name: "PageCaptureUITests",
            dependencies: ["PageCaptureUI"]
        ),
    ]
)
