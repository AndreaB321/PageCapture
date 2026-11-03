// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PageCapture",
    platforms: [.macOS(.v14)],
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
        .testTarget(
            name: "PageCaptureCoreTests",
            dependencies: ["PageCaptureCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PageCaptureUITests",
            dependencies: ["PageCaptureUI"]
        ),
    ]
)
