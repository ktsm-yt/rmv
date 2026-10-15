import CoreGraphics
import Foundation

enum Zoom {
    static let minimum: CGFloat = 0.25
    static let maximum: CGFloat = 4
    static let step: CGFloat = 1.2
    private static let pageZoomKey = "pageZoom"
    private static let magnificationKey = "magnification"

    static func clamped(_ magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite else { return 1 }
        return min(max(magnification, minimum), maximum)
    }

    static func restoredValue(_ value: Double?) -> CGFloat {
        guard let value, value.isFinite else { return 1 }
        return clamped(CGFloat(value))
    }

    static func restoredPageZoom(defaults: UserDefaults = .standard) -> CGFloat {
        restoredValue(defaults.object(forKey: pageZoomKey) as? Double)
    }

    static func restoredMagnification(defaults: UserDefaults = .standard) -> CGFloat {
        restoredValue(defaults.object(forKey: magnificationKey) as? Double)
    }

    static func save(pageZoom: CGFloat, magnification: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clamped(pageZoom)), forKey: pageZoomKey)
        defaults.set(Double(clamped(magnification)), forKey: magnificationKey)
    }

}
