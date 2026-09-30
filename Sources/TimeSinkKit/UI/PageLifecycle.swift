import SwiftUI

// Main-window pages stay alive behind the visible one (`MainWindowView`), so
// work and chrome that used to end with the page must now pause with it.
//
// Visibility travels as an observable object injected once per page, not as
// an environment value: changing an environment value makes every text in
// the page resolve and lay out again. Only the modifiers below read it.

/// Whether a kept-alive page is the one on screen. Read straight from the
/// sidebar selection, so a page's chrome and tasks switch in the same update
/// as the page itself rather than one frame later.
@MainActor @Observable
final class PageVisibility {
    private let model: AppModel
    private let page: SidebarItem

    init(model: AppModel, page: SidebarItem) {
        self.model = model
        self.page = page
    }

    var isShown: Bool { model.sidebarSelection == page }
}

@propertyWrapper
private struct PageShown: DynamicProperty {
    @Environment(PageVisibility.self) private var visibility: PageVisibility?
    /// Outside the main window, a view is always on screen.
    @MainActor var wrappedValue: Bool { visibility?.isShown ?? true }
}

extension View {
    /// `onChange(of:)` for a page that stays alive while hidden: a change
    /// made while the page is hidden runs `action` once, on return. `value`
    /// is read only while the page is shown, so a hidden page that watches
    /// the data version is not rebuilt on every tracker write.
    func onPageChange<V: Equatable>(of value: @autoclosure @escaping () -> V,
                                    perform action: @escaping () -> Void) -> some View {
        modifier(PageChange(value: value, action: action))
    }

    /// `task(id:)` for a page that stays alive while hidden: runs while the
    /// page is shown, and on return only if `id` moved while it was hidden.
    func pageTask<ID: Equatable>(id: @autoclosure @escaping () -> ID,
                                 _ action: @escaping () async -> Void) -> some View {
        modifier(PageTask(id: id, action: action))
    }

    /// A `task` that runs while the page is shown and restarts on return.
    func whilePageShown(_ action: @escaping () async -> Void) -> some View {
        modifier(PageTask(id: { true }, action: action, repeats: true))
    }

    /// Called with `true` when the page is shown again, `false` when hidden.
    func onPageVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(PageVisibilityChange(action: action))
    }

    /// `searchable` whose field leaves the window toolbar with its page.
    func pageSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        modifier(PageSearch(text: text, prompt: prompt))
    }

    /// Toolbar items that leave the window toolbar with their page.
    func pageToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(PageToolbar(items: items()))
    }

    /// An inspector that closes with its page and opens again on return.
    func pageInspector<Inspector: View>(isPresented: Binding<Bool>,
                                        @ViewBuilder content: () -> Inspector) -> some View {
        modifier(PageInspector(isPresented: isPresented, inspector: content()))
    }
}

private struct PageChange<V: Equatable>: ViewModifier {
    let value: () -> V
    let action: () -> Void
    @PageShown private var isActive
    @State private var seen: V?

    func body(content: Content) -> some View {
        content.onChange(of: isActive ? value() : nil, initial: true) { _, current in
            guard let current else { return }
            if let seen, seen != current { action() }
            seen = current
        }
    }
}

private struct PageTask<ID: Equatable>: ViewModifier {
    let id: () -> ID
    let action: () async -> Void
    var repeats = false
    @PageShown private var isActive
    @State private var done: ID?

    func body(content: Content) -> some View {
        let current = isActive ? id() : nil
        content.task(id: current) {
            guard let current, repeats || current != done else { return }
            await action()
            if !Task.isCancelled { done = current }
        }
    }
}

private struct PageVisibilityChange: ViewModifier {
    let action: (Bool) -> Void
    @PageShown private var isActive

    func body(content: Content) -> some View {
        content.onChange(of: isActive) { _, active in action(active) }
    }
}

private struct PageSearch: ViewModifier {
    let text: Binding<String>
    let prompt: LocalizedStringKey
    @PageShown private var isActive

    func body(content: Content) -> some View {
        // On a sibling, so hiding the field does not rebuild the page.
        content.background { if isActive { Color.clear.searchable(text: text, prompt: prompt) } }
    }
}

private struct PageToolbar<Items: ToolbarContent>: ViewModifier {
    let items: Items
    @PageShown private var isActive

    func body(content: Content) -> some View {
        content.toolbar { if isActive { items } }
    }
}

private struct PageInspector<Inspector: View>: ViewModifier {
    @Binding var isPresented: Bool
    let inspector: Inspector
    @PageShown private var isActive

    func body(content: Content) -> some View {
        // The inspector column belongs to the window, not the page.
        content.inspector(isPresented: Binding(get: { isPresented && isActive },
                                               set: { if isActive { isPresented = $0 } })) {
            inspector
        }
    }
}
