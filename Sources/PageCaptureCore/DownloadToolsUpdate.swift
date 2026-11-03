import Foundation

/// What **Update Download Tools** reports (SPEC "Videos"): yt-dlp's version before and after its
/// own updater ran, or why it failed.
public struct DownloadToolsUpdate: Equatable, Sendable {
    public var succeeded: Bool
    public var title: String
    public var message: String

    /// Runs yt-dlp's updater on its working copy, reading its version before and after.
    public static func run(with tools: Tools) async -> DownloadToolsUpdate {
        do {
            let before = try await version(tools)
            let result = try await tools.updateYtDlp()
            let after = try await version(tools)
            return summary(before: before, after: after, result: result)
        } catch ToolError.missing(let url) {
            return DownloadToolsUpdate(succeeded: false, title: "yt-dlp could not be updated",
                                       message: "yt-dlp is missing at \(url.path).")
        } catch {
            return DownloadToolsUpdate(succeeded: false, title: "yt-dlp could not be updated",
                                       message: error.localizedDescription)
        }
    }

    static func summary(before: String?, after: String?, result: ToolResult) -> DownloadToolsUpdate {
        let unknown = "unknown"
        guard result.succeeded else {
            // yt-dlp ends with its own error line, e.g. "ERROR: Unable to download latest version".
            let lines = (result.stderr + "\n" + result.stdout).split(whereSeparator: \.isNewline)
            let reason = lines.last { $0.contains("ERROR") } ?? lines.last ?? "yt-dlp exited with status \(result.status)."
            return DownloadToolsUpdate(succeeded: false, title: "yt-dlp could not be updated",
                                       message: "\(reason.trimmingCharacters(in: .whitespaces))\nVersion: \(before ?? unknown)")
        }
        if let before, before == after {
            return DownloadToolsUpdate(succeeded: true, title: "yt-dlp is up to date", message: "Version: \(before)")
        }
        return DownloadToolsUpdate(succeeded: true, title: "yt-dlp was updated",
                                   message: "Before: \(before ?? unknown)\nAfter: \(after ?? unknown)")
    }

    /// `yt-dlp --version`, or nil if it printed nothing or failed.
    private static func version(_ tools: Tools) async throws -> String? {
        let result = try await tools.run(.ytDlp, arguments: ["--version"])
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !version.isEmpty ? version : nil
    }
}
