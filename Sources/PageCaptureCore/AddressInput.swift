import Foundation

/// Turns what the user typed in the address bar into a URL to load.
public enum AddressInput {
    public static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme,
           ["http", "https", "file", "about"].contains(scheme.lowercased()) {
            return url
        }
        return URL(string: "https://" + text)
    }
}
