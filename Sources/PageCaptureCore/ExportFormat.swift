import AppKit

/// What is being saved: the page formats or the document formats are offered (SPEC "Saving", "Documents").
public enum ExportSaveKind: Sendable {
    case page
    case document

    /// The formats the save panel offers, in its order.
    public var formats: [ExportFormat] {
        switch self {
        case .page: [.html, .pdf, .markdown]
        case .document: [.original, .markdown]
        }
    }
}

/// One of the formats the save panel offers (SPEC "Saving").
public enum ExportFormat: String, CaseIterable, Sendable {
    case html
    case pdf
    case markdown
    /// A document's original file, unchanged.
    case original

    public var title: String {
        switch self {
        case .html: "HTML"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .original: "Original"
        }
    }
}

/// The ticked formats, remembered between saves, separately for pages and documents.
public enum ExportFormatPreference {
    static let key = "exportFormats"
    static let documentKey = "documentExportFormats"
    /// The popup's choice before formats were ticked: "pdf", "markdown" or "both".
    static let legacyKey = "exportFormat"

    /// The stored set for `kind`; for pages on the first run after the change, the old popup's choice.
    public static func load(from defaults: UserDefaults, kind: ExportSaveKind = .page) -> Set<ExportFormat> {
        let offered = kind.formats
        if let stored = defaults.stringArray(forKey: kind == .page ? key : documentKey) {
            let formats = Set(stored.compactMap(ExportFormat.init(rawValue:)).filter(offered.contains))
            if !formats.isEmpty { return formats }
        }
        if kind == .document { return Set(offered) }
        switch defaults.string(forKey: legacyKey) {
        case "pdf": return [.pdf]
        case "markdown": return [.markdown]
        default: return [.pdf, .markdown]
        }
    }

    public static func save(_ formats: Set<ExportFormat>, to defaults: UserDefaults, kind: ExportSaveKind = .page) {
        let stored = kind.formats.filter(formats.contains).map(\.rawValue)
        switch kind {
        case .page:
            defaults.set(stored, forKey: key)
            defaults.removeObject(forKey: legacyKey)
        case .document:
            defaults.set(stored, forKey: documentKey)
        }
    }
}

/// The save panel's accessory: one checkbox per format `kind` offers. Unticking the last ticked box
/// ticks it again, so at least one format is always chosen.
@MainActor
public final class FormatChooser: NSObject {
    public let view: NSView
    /// In `kind.formats` order.
    public let checkboxes: [NSButton]
    private let formats: [ExportFormat]

    /// - Parameter original: for a document, its type, which the Original checkbox names ("Original (.pdf)").
    public init(selection: Set<ExportFormat>, kind: ExportSaveKind = .page, original: DocumentKind? = nil) {
        formats = kind.formats
        let boxes = kind.formats.map { format in
            let title = if format == .original, let original { "\(format.title) (.\(original.fileExtension))" } else { format.title }
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = selection.contains(format) ? .on : .off
            return box
        }
        checkboxes = boxes
        let stack = NSStackView(views: [NSTextField(labelWithString: "Formats:")] + boxes)
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        view = stack
        super.init()
        for box in boxes {
            box.target = self
            box.action = #selector(toggled(_:))
        }
    }

    public var selection: Set<ExportFormat> {
        Set(zip(formats, checkboxes).filter { $0.1.state == .on }.map(\.0))
    }

    @objc private func toggled(_ sender: NSButton) {
        if selection.isEmpty { sender.state = .on }
    }
}
