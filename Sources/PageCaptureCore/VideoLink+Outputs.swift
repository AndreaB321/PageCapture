extension VideoLink {
    /// What Markdown and PDF say after a video that was not saved (SPEC "Videos"), without the
    /// surrounding parentheses and italics.
    var note: String? {
        switch outcome {
        case .saved: nil
        case .protected: "protected video, linked to the original"
        case .failed(let reason): "video could not be saved: \(reason)"
        }
    }

    /// Whether `href` is a path inside the capture folder rather than the original URL.
    var isLocal: Bool { outcome == .saved }
}
