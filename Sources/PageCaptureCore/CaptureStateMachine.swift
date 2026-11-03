/// What a capture is aimed at once the user has picked.
public enum CaptureTarget: Equatable, Sendable {
    /// The main frame's document scrolling element.
    case wholePage
    /// A frame document or scrollable element chosen with the picker. The page bridge remembers
    /// which frame and element it was.
    case picked
}

/// The phases of the ⌘⇧S flow (SPEC "Shortcut and banner").
public enum CapturePhase: Equatable, Sendable {
    case idle
    case picking
    case capturing(CaptureTarget)
    /// The user asked to stop; the collector is returning what it has.
    case stopping(CaptureTarget)
    /// Collection ended; the save step owns the screen.
    case saving
}

public enum CaptureEvent: Equatable, Sendable {
    /// ⌘⇧S.
    case shortcut
    case escape
    /// Return picks the whole page.
    case returnKey
    /// A click in the page picked a target (clicking outside any target picks `.wholePage`).
    case picked(CaptureTarget)
    /// The collector returned content: it reached the bottom, or it honoured a stop.
    case collectionEnded
    case collectionFailed
    /// The save step finished or was dismissed.
    case saveFinished
    /// The main frame committed a navigation: whatever the picker or collector was aimed at is gone.
    case navigated
}

/// Side effects the app performs in response to a transition.
public enum CaptureEffect: Equatable, Sendable {
    case beginPicking
    case endPicking
    case beginCollection(CaptureTarget)
    case stopCollection
    /// Drop a running collection without saving: its result, if it ever arrives, is ignored.
    case abortCollection
    case presentSave
}

/// Pure state machine for the capture flow. The app feeds it events and performs the effects.
public struct CaptureStateMachine: Equatable, Sendable {
    public private(set) var phase: CapturePhase = .idle

    public init() {}

    /// Banner text for the current phase; `nil` means no banner.
    public var bannerText: String? {
        switch phase {
        case .picking: "Pick a frame, scrolling area or article… (Return = whole page, Esc = cancel)"
        case .capturing, .stopping: "Capturing…"
        case .idle, .saving: nil
        }
    }

    @discardableResult
    public mutating func handle(_ event: CaptureEvent) -> [CaptureEffect] {
        switch (phase, event) {
        case (.idle, .shortcut):
            phase = .picking
            return [.beginPicking]

        case (.picking, .shortcut), (.picking, .escape):
            phase = .idle
            return [.endPicking]

        case (.picking, .returnKey):
            return begin(.wholePage)

        case let (.picking, .picked(target)):
            return begin(target)

        case let (.capturing(target), .shortcut):
            phase = .stopping(target)
            return [.stopCollection]

        // ⌘⇧S again while stopping: the collector did not answer, so give up on it (nothing is saved).
        case (.stopping, .shortcut):
            phase = .idle
            return [.abortCollection]

        case (.picking, .navigated):
            phase = .idle
            return [.endPicking]

        case (.capturing, .navigated), (.stopping, .navigated):
            phase = .idle
            return [.abortCollection]

        case (.capturing, .collectionEnded), (.stopping, .collectionEnded):
            phase = .saving
            return [.presentSave]

        case (.capturing, .collectionFailed), (.stopping, .collectionFailed):
            phase = .idle
            return []

        case (.saving, .saveFinished):
            phase = .idle
            return []

        default:
            return []
        }
    }

    private mutating func begin(_ target: CaptureTarget) -> [CaptureEffect] {
        phase = .capturing(target)
        return [.endPicking, .beginCollection(target)]
    }
}
