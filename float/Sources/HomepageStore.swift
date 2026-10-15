import Foundation

enum HomepageStore {
    static let defaultURL = URL(string: "http://127.0.0.1:4310/")!
    private static let key = "homepageURL"

    static func validatedURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return url
    }

    static func homepage(defaults: UserDefaults = .standard) -> URL {
        defaults.string(forKey: key).flatMap(validatedURL) ?? defaultURL
    }

    static func save(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.absoluteString, forKey: key)
    }
}
