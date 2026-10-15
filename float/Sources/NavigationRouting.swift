import Foundation

enum NavigationRouting {
    static func shouldOpenExternally(
        isLinkActivated: Bool,
        opensNewFrame: Bool,
        requestURL: URL,
        currentURL: URL?
    ) -> Bool {
        if opensNewFrame { return true }
        return isLinkActivated && !isSameDocument(requestURL, currentURL)
    }

    static func isAllowedExternalURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return HomepageStore.validatedURL(url.absoluteString) != nil
        case "mailto":
            return !url.path.isEmpty
        case "vscode":
            return url.host?.isEmpty == false
        default:
            return false
        }
    }

    private static func isSameDocument(_ requestURL: URL, _ currentURL: URL?) -> Bool {
        guard var request = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              var current = currentURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return requestURL == currentURL
        }
        request.fragment = nil
        current.fragment = nil
        return request == current
    }
}
