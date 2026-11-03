import PageCaptureCore
import SwiftUI
import WebKit

/// The browser window: header bar with the address field above the web view, with the capture
/// banner and the launch credit overlaid on it.
public struct BrowserView: View {
    let controller: CaptureController
    @State private var address = ""
    @State private var showsCredit: Bool

    /// `showsCredit: false` starts without the launch credit (the manual's screenshot harness).
    public init(controller: CaptureController, showsCredit: Bool = true) {
        self.controller = controller
        _showsCredit = State(initialValue: showsCredit)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderBar(controller: controller, address: $address, onSubmit: load)
            WebView(webView: controller.webView)
                .overlay(alignment: .top) {
                    if let text = controller.bannerText {
                        BannerView(text: text)
                            .padding(.top, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: controller.bannerText)
        }
        .overlay {
            if showsCredit {
                CreditView { showsCredit = false }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsCredit)
        .tint(Theme.navy)
        .onReceive(controller.webView.publisher(for: \.url)) { url in
            if let url { address = url.absoluteString }
        }
    }

    private func load() {
        guard let url = AddressInput.url(from: address) else { return }
        controller.webView.load(URLRequest(url: url))
    }
}

/// Soft coral bar in the icon's colours: app icon and name, address field, capture button.
struct HeaderBar: View {
    let controller: CaptureController
    @Binding var address: String
    let onSubmit: () -> Void

    /// The author's avatar (Assets/header-avatar.png, copied into the bundle); the app icon when run
    /// outside the bundle.
    private static let avatar: NSImage =
        Bundle.main.image(forResource: "header-avatar") ?? NSApp.applicationIconImage

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Self.avatar)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text("PageCapture")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.navy)
            NavigationButtons(webView: controller.webView)
            // Own placeholder: the system one ignores the colour and is too faint on the field.
            TextField("", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.navy)
                .background(alignment: .leading) {
                    if address.isEmpty {
                        Text("Enter a URL")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.placeholder)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.navy.opacity(0.35), lineWidth: 1))
                .onSubmit(onSubmit)
            Button { controller.send(.shortcut) } label: {
                Text("\(controller.shortcutTitle)  ⌘⇧S")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.navy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.butter))
                    .overlay(Capsule().strokeBorder(Theme.navy.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!controller.shortcutEnabled)
            .opacity(controller.shortcutEnabled ? 1 : 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LinearGradient(colors: [Theme.coralLight, Theme.coral], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Theme.navy.opacity(0.2).frame(height: 1) }
    }
}

struct BannerView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.coral).frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.cream)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.navy))
        .overlay(Capsule().strokeBorder(Theme.butter, lineWidth: 2))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .allowsHitTesting(false)
    }
}

/// Shown at launch; OK dismisses it, otherwise it goes away after 5 seconds.
struct CreditView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Designed and built by Andrea B 🇮🇹 🍕 🤌🏻")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.cream)
            Button(action: dismiss) {
                Text("OK")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.navy)
                    .frame(width: 80)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.butter))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // Navy, not cream: the light-skin 🤌🏻 and the flag's white stripe vanish on a light card.
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.navy))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.coral, lineWidth: 2))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        .task {
            try? await Task.sleep(for: .seconds(5))
            dismiss()
        }
    }
}

/// Hosts the controller's single WKWebView.
struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Back and forward for the browser (also ⌘[ and ⌘]), enabled while there is history that way.
struct NavigationButtons: View {
    let webView: WKWebView
    @State private var canGoBack = false
    @State private var canGoForward = false

    var body: some View {
        HStack(spacing: 2) {
            button("chevron.left", help: "Back", enabled: canGoBack) { webView.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            button("chevron.right", help: "Forward", enabled: canGoForward) { webView.goForward() }
                .keyboardShortcut("]", modifiers: .command)
        }
        .onReceive(webView.publisher(for: \.canGoBack)) { canGoBack = $0 }
        .onReceive(webView.publisher(for: \.canGoForward)) { canGoForward = $0 }
    }

    private func button(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.navy)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Enabled: navy on the coral header, 6.5-7.9:1. Disabled: still at least 3:1, just fainter.
        .opacity(enabled ? 1 : 0.65)
        .help(help)
        .accessibilityLabel(help)
    }
}
