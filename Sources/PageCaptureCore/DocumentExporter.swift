import Foundation

/// Why a document's Markdown was not written; the original is kept instead.
public enum DocumentMarkdownFailure: Equatable, Sendable {
    /// Neither MarkItDown nor text recognition found any text.
    case noTextFound
    /// The conversion failed; the reason holds no paths.
    case failed(String)

    /// For the result message.
    public var note: String {
        switch self {
        case .noTextFound: "no text found in the document; the original was kept"
        case .failed(let reason): "the Markdown could not be made (\(reason)); the original was kept"
        }
    }
}

/// Saves a downloaded document (SPEC "Documents"): `folder/` gets `Name.<ext>` (the original,
/// unchanged) and/or `Name.md`, where `Name` is the folder's name.
public enum DocumentExporter {
    /// - Parameters:
    ///   - file: the downloaded original (`DownloadedDocument.file`); it is copied, not moved.
    ///   - formats: `.original` and/or `.markdown`. When the Markdown cannot be made, the original is
    ///     written even if it was not chosen.
    public static func export(
        _ file: URL,
        kind: DocumentKind,
        formats: Set<ExportFormat>,
        to folder: URL,
        converter: DocumentConverter = DocumentConverter()
    ) async throws -> ExportResult {
        let fileManager = FileManager.default
        let name = folder.lastPathComponent
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var result = ExportResult(folder: folder, failedImages: [])

        if formats.contains(.markdown) {
            do {
                let markdown = try await converter.markdown(forFile: file)
                let url = folder.appendingPathComponent("\(name).md")
                try Data(markdown.utf8).write(to: url, options: .atomic)
                result.markdown = url
            } catch DocumentConversionError.noTextFound {
                result.documentMarkdownFailure = .noTextFound
            } catch let error as DocumentConversionError {
                result.documentMarkdownFailure = .failed(reason(for: error))
            }
        }
        try Task.checkCancellation()
        if formats.contains(.original) || result.documentMarkdownFailure != nil {
            let url = folder.appendingPathComponent("\(name).\(kind.fileExtension)")
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try fileManager.copyItem(at: file, to: url)
            result.original = url
        }
        return result
    }

    /// A short reason for the result message, without paths.
    static func reason(for error: DocumentConversionError) -> String {
        switch error {
        case .runtimeMissing: "the document converter is missing"
        case .timedOut: "it took too long"
        case .failed(_, let message), .stopped(_, let message):
            // The end of stderr; its last line names the error (e.g. `FileConversionException: …`).
            lastLine(of: message).map { String($0.prefix(300)) } ?? "the converter failed"
        case .outputTooLarge: "the Markdown would be too large"
        case .unreadable: "the document could not be read"
        case .noTextFound: "no text found"
        case .notAFile, .unreadableInput: "the downloaded file could not be read"
        case .inputTooLarge: "the document is too large to convert"
        }
    }

    private static func lastLine(of text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }
}
