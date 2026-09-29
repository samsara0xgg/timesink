import AppKit
import Carbon
import SwiftUI

/// Carbon hot keys require neither keyboard monitoring nor Accessibility permission.
@MainActor final class PopoverShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredKey: UInt32?
    private var registeredModifiers: UInt32?
    var action: (() -> Void)?
    private(set) var available = false
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_T), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        // Also when the last attempt failed: a taken combination stays taken,
        // and the menu label calls this on every render.
        if registeredKey == keyCode, registeredModifiers == modifiers { return }
        unregister()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<PopoverShortcut>.fromOpaque(pointer).takeUnretainedValue().action?() }
            return noErr
        }, 1, &type, context, &handler) == noErr else { return }
        available = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x54534E4B, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
        registeredKey = keyCode; registeredModifiers = modifiers
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; available = false
        registeredKey = nil; registeredModifiers = nil
    }
}

extension AppModel {
    var popoverShortcutLabel: String { settings.get("popoverShortcutLabel") ?? "⌃⌥T" }
    func registerPopoverShortcut() {
        popoverShortcut.register(keyCode: UInt32(settings.get("popoverShortcutKey") ?? "") ?? UInt32(kVK_ANSI_T), modifiers: UInt32(settings.get("popoverShortcutModifiers") ?? "") ?? UInt32(controlKey | optionKey))
        popoverShortcutAvailable = popoverShortcut.available
    }
    func setPopoverShortcut(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty,
              let character = event.charactersIgnoringModifiers?.uppercased(), character.count == 1,
              character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return false }
        var modifiers: UInt32 = 0, label = ""
        for (flag, carbon, glyph) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
            modifiers |= UInt32(carbon); label += glyph
        }
        popoverShortcut.register(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard popoverShortcut.available else { registerPopoverShortcut(); return false }
        settings.set("popoverShortcutKey", String(event.keyCode)); settings.set("popoverShortcutModifiers", String(modifiers)); settings.set("popoverShortcutLabel", label + character)
        popoverShortcutAvailable = true
        settingsChanged()
        return true
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> Recorder { Recorder(model: model) }
    func updateNSView(_ view: Recorder, context: Context) { view.refresh() }
    final class Recorder: NSButton {
        let model: AppModel
        private var recording = false
        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            bezelStyle = .rounded; target = self; action = #selector(begin)
            setAccessibilityLabel(String(localized: "修改打开弹出层的快捷键"))
            refresh()
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        @objc private func begin() { recording = true; window?.makeFirstResponder(self); refresh() }
        func refresh() {
            title = recording ? String(localized: "按下快捷键…") : model.popoverShortcutLabel
            toolTip = String(localized: "点击后按住 Control、Option 或 Command，再按字母或数字；Esc 取消。")
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) { recording = false; refresh(); return }
            if model.setPopoverShortcut(event: event) { recording = false; refresh() }
            else { title = String(localized: "不可用，请重试"); NSSound.beep() }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event); return true
        }
        override func resignFirstResponder() -> Bool { recording = false; refresh(); return super.resignFirstResponder() }
    }
}

/// Locate only the public NSStatusBarButton that owns this label. No global UI search.
struct StatusButtonBridge: NSViewRepresentable {
    let onResolve: (NSStatusBarButton) -> Void
    func makeNSView(context: Context) -> Probe { Probe(onResolve: onResolve) }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.resolve() }
    final class Probe: NSView {
        let onResolve: (NSStatusBarButton) -> Void
        init(onResolve: @escaping (NSStatusBarButton) -> Void) { self.onResolve = onResolve; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolve() }
        func resolve() {
            var ancestor: NSView? = superview
            while let view = ancestor {
                if let button = view as? NSStatusBarButton { onResolve(button); return }
                ancestor = view.superview
            }
        }
    }
}
