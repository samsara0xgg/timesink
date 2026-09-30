import AppKit
import ApplicationServices
import Carbon

/// F3 回到刚才: watches the tracker's ticks and brings back the window left
/// for an interruption, from the menu bar, the ⋯ menu or ⌃⌥←.
extension AppModel {
    public var returnEnabled: Bool { settings.get("returnOfferEnabled") != "false" }

    func observeForReturn(_ span: Span?, now: Date) {
        guard returnEnabled else { if returnOffer != nil { setReturnOffer(nil) }; return }
        var productivity = 0, distracting = false
        if let span {
            // Categorize once per window, not once per second.
            let categoryID: String
            if let cached = returnCategory, cached.start == span.start, cached.bundleID == span.appBundleID {
                categoryID = cached.categoryID
            } else {
                categoryID = resolver.categoryID(for: span)
                returnCategory = (span.start, span.appBundleID, categoryID)
            }
            productivity = resolver.categoriesByID[categoryID]?.productivity ?? 0
            distracting = InterruptionRule.distractingCategories.contains(categoryID)
        }
        returnTracker.observe(current: span, productivity: productivity, distracting: distracting, now: now,
                              rule: interruptionRule, focusing: focus?.running != nil)
        if returnTracker.offer != returnOffer { setReturnOffer(returnTracker.offer) }
    }

    /// ⌃⌥← is taken only while there is somewhere to go back to, so other
    /// apps keep the combination the rest of the time.
    func setReturnOffer(_ offer: ReturnTracker.Origin?) {
        returnOffer = offer
        if offer == nil {
            returnShortcut.unregister()
        } else {
            returnShortcut.action = { [weak self] in self?.goBack() }
            returnShortcut.register(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey))
        }
    }

    /// Activates the app and, with Accessibility (already granted for
    /// recording), raises the window by its title. No scroll position.
    func goBack() {
        guard let offer = returnOffer,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: offer.bundleID).first else { return }
        app.activate()
        if let title = offer.title, !title.isEmpty, AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success {
                for window in windows as? [AXUIElement] ?? [] {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
                    if value as? String == title {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        break
                    }
                }
            }
        }
        returnTracker.clearOffer()
        setReturnOffer(nil)
    }
}
