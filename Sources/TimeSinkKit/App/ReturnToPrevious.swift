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
            distracting = resolver.distractingIDs.contains(categoryID)
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
            // Ticks stop while you are away; the capsule still leaves on time.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(ReturnTracker.offerLifetime))
                guard let self, self.returnOffer == offer else { return }
                self.returnTracker.clearOffer()
                self.setReturnOffer(nil)
            }
        }
    }

    /// Activates the app and, with Accessibility (already granted for
    /// recording), raises the window by its title; in Chrome, the tab by its
    /// page. No scroll position. The Apple Event and the Accessibility calls
    /// run off the main actor: a busy app can hold either for seconds.
    func goBack() {
        guard let offer = returnOffer,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: offer.bundleID).first else { return }
        app.activate()
        returnTracker.clearOffer()
        setReturnOffer(nil)
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            if offer.bundleID == "com.google.Chrome", let url = offer.url, await ChromeBlocker().activateTabOffActor(url: url) { return }
            if let title = offer.title, !title.isEmpty, AXIsProcessTrusted() { raiseWindow(pid: pid, title: title) }
        }
    }
}

/// Raises the app's window called `title`, through Accessibility.
private func raiseWindow(pid: pid_t, title: String) {
    let element = AXUIElementCreateApplication(pid)
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success else { return }
    for window in windows as? [AXUIElement] ?? [] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        if value as? String == title {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            break
        }
    }
}
