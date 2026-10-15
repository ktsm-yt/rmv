import Foundation

@main
struct HomepageStoreTests {
    static func main() {
        let accepted = ["http://127.0.0.1:4310/", "https://example.com/path?q=1"]
        let rejected = ["", "about:blank", "file:///tmp/test", "javascript:alert(1)", "ftp://example.com", "http:///missing-host"]
        precondition(accepted.allSatisfy { HomepageStore.validatedURL($0) != nil })
        precondition(rejected.allSatisfy { HomepageStore.validatedURL($0) == nil })
        precondition(Zoom.clamped(0.1) == Zoom.minimum)
        precondition(Zoom.clamped(5) == Zoom.maximum)
        precondition(Zoom.clamped(1.2) == 1.2)
        precondition(Zoom.restoredValue(nil) == 1)
        precondition(Zoom.restoredValue(.nan) == 1)
        precondition(Zoom.restoredValue(.infinity) == 1)
        precondition(Zoom.restoredValue(0.1) == Zoom.minimum)
        precondition(Zoom.restoredValue(5) == Zoom.maximum)
        Zoom.clearSavedValues()
        Zoom.save(pageZoom: 1.2, magnification: 1.5)
        precondition(Zoom.restoredPageZoom == 1.2)
        precondition(Zoom.restoredMagnification == 1.5)
        Zoom.clearSavedValues()
        precondition(Zoom.restoredPageZoom == 1)
        precondition(Zoom.restoredMagnification == 1)
        let current = URL(string: "http://127.0.0.1:4310/work?id=1")!
        let external = URL(string: "https://example.com/")!
        let anchor = URL(string: "http://127.0.0.1:4310/work?id=1#reply")!
        precondition(NavigationRouting.shouldOpenExternally(isLinkActivated: true, opensNewFrame: false, requestURL: external, currentURL: current))
        precondition(!NavigationRouting.shouldOpenExternally(isLinkActivated: true, opensNewFrame: false, requestURL: anchor, currentURL: current))
        precondition(NavigationRouting.shouldOpenExternally(isLinkActivated: false, opensNewFrame: true, requestURL: external, currentURL: current))
        precondition(!NavigationRouting.shouldOpenExternally(isLinkActivated: false, opensNewFrame: false, requestURL: external, currentURL: current))
        precondition(NavigationRouting.isAllowedExternalURL(external))
        precondition(NavigationRouting.isAllowedExternalURL(URL(string: "mailto:hello@example.com")!))
        precondition(NavigationRouting.isAllowedExternalURL(URL(string: "vscode://file/tmp/example.swift")!))
        precondition(!NavigationRouting.isAllowedExternalURL(URL(string: "file:///tmp/example.swift")!))
        precondition(!NavigationRouting.isAllowedExternalURL(URL(string: "javascript:alert(1)")!))
        let expected = URL(string: "https://example.com/")!
        HomepageStore.save(expected)
        precondition(HomepageStore.homepage == expected)
        UserDefaults.standard.removeObject(forKey: "homepageURL")
        print("HomepageStore tests passed")
    }
}
