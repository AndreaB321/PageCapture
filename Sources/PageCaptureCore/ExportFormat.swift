import AppKit

/// One of the formats the save panel offers (SPEC "Saving"), in the panel's order.
public enum ExportFormat: String, CaseIterable, Sendable {
    case html
    case pdf
    case markdown

    public var title: String {
        switch self {
        case .html: "HTML"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        }
    }
}

/// The ticked formats, remembered between saves.
public enum ExportFormatPreference {
    static let key = "exportFormats"
    /// The popup's choice before formats were ticked: "pdf", "markdown" or "both".
    static let legacyKey = "exportFormat"

    /// The stored set; on the first run after the change, the old popup's choice.
    public static func load(from defaults: UserDefaults) -> Set<ExportFormat> {
        if let stored = defaults.stringArray(forKey: key) {
            let formats = Set(stored.compactMap(ExportFormat.init(rawValue:)))
            if !formats.isEmpty { return formats }
        }
        switch defaults.string(forKey: legacyKey) {
        case "pdf": return [.pdf]
        case "markdown": return [.markdown]
        default: return [.pdf, .markdown]
        }
    }

    public static func save(_ formats: Set<ExportFormat>, to defaults: UserDefaults) {
        defaults.set(ExportFormat.allCases.filter(formats.contains).map(\.rawValue), forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }
}

/// The save panel's accessory: one checkbox per format. Unticking the last ticked box ticks it again,
/// so at least one format is always chosen.
@MainActor
public final class FormatChooser: NSObject {
    public let view: NSView
    /// In `ExportFormat.allCases` order.
    public let checkboxes: [NSButton]

    public init(selection: Set<ExportFormat>) {
        let boxes = ExportFormat.allCases.map { format in
            let box = NSButton(checkboxWithTitle: format.title, target: nil, action: nil)
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
        Set(zip(ExportFormat.allCases, checkboxes).filter { $0.1.state == .on }.map(\.0))
    }

    @objc private func toggled(_ sender: NSButton) {
        if selection.isEmpty { sender.state = .on }
    }
}
