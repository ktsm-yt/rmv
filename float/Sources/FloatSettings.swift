import CoreGraphics
import Foundation

enum FloatSettings {
    private static let alwaysOnTopKey = "alwaysOnTop"
    private static let opacityKey = "windowOpacity"

    static let minimumOpacity: CGFloat = 0.2
    static let maximumOpacity: CGFloat = 1

    static func clampedOpacity(_ value: Double) -> CGFloat {
        guard value.isFinite else { return maximumOpacity }
        return min(max(CGFloat(value), minimumOpacity), maximumOpacity)
    }

    static func alwaysOnTop(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: alwaysOnTopKey) as? Bool ?? true
    }

    static func opacity(defaults: UserDefaults = .standard) -> CGFloat {
        clampedOpacity(defaults.object(forKey: opacityKey) as? Double ?? Double(maximumOpacity))
    }

    static func save(alwaysOnTop: Bool, opacity: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(alwaysOnTop, forKey: alwaysOnTopKey)
        defaults.set(Double(clampedOpacity(Double(opacity))), forKey: opacityKey)
    }
}
