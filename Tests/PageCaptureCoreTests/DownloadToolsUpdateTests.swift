import XCTest
@testable import PageCaptureCore

final class DownloadToolsUpdateTests: XCTestCase {
    private func result(_ status: Int32, stdout: String = "", stderr: String = "") -> ToolResult {
        ToolResult(status: status, stdout: stdout, stderr: stderr)
    }

    func testReportsTheVersionsBeforeAndAfterAnUpdate() {
        let update = DownloadToolsUpdate.summary(before: "2026.10.01", after: "2026.11.01", result: result(0))
        XCTAssertEqual(update, DownloadToolsUpdate(succeeded: true, title: "yt-dlp was updated",
                                                   message: "Before: 2026.10.01\nAfter: 2026.11.01"))
    }

    func testSameVersionIsUpToDate() {
        let update = DownloadToolsUpdate.summary(before: "2026.11.01", after: "2026.11.01", result: result(0))
        XCTAssertEqual(update, DownloadToolsUpdate(succeeded: true, title: "yt-dlp is up to date",
                                                   message: "Version: 2026.11.01"))
    }

    func testFailureShowsYtDlpsErrorLineAndTheVersion() {
        let update = DownloadToolsUpdate.summary(
            before: "2026.10.01", after: "2026.10.01",
            result: result(1, stdout: "Current version: stable@2026.10.01\n",
                           stderr: "WARNING: something\nERROR: Unable to write to /x/yt-dlp; check permissions\n"))
        XCTAssertEqual(update, DownloadToolsUpdate(
            succeeded: false, title: "yt-dlp could not be updated",
            message: "ERROR: Unable to write to /x/yt-dlp; check permissions\nVersion: 2026.10.01"))
    }

    func testFailureWithoutOutputGivesTheStatus() {
        let update = DownloadToolsUpdate.summary(before: nil, after: nil, result: result(9))
        XCTAssertEqual(update.message, "yt-dlp exited with status 9.\nVersion: unknown")
        XCTAssertFalse(update.succeeded)
    }

    func testMissingToolIsReported() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadToolsUpdateTests-\(UUID())")
        let update = await DownloadToolsUpdate.run(with: Tools(helpersDirectory: empty, supportDirectory: empty))
        XCTAssertEqual(update, DownloadToolsUpdate(
            succeeded: false, title: "yt-dlp could not be updated",
            message: "yt-dlp is missing at \(empty.appendingPathComponent("yt-dlp").path)."))
    }
}
