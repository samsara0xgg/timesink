import SwiftUI

/// Shared permission status: the Settings permissions list and the
/// onboarding step. Status color and text are derived from `state` in one
/// place so callers never branch on the underlying OSStatus/Bool themselves.
/// It draws no container; a Form row or the caller's panel provides one.
struct PermissionRow: View {
    let title: String
    var explanation: String? = nil
    let state: PermissionState
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(title).font(.body.weight(.semibold))
                Spacer()
                Text(statusText).font(.note).foregroundStyle(statusColor)
            }
            if let explanation {
                Text(explanation).font(.body).foregroundStyle(Design.ink2)
            }
            Button(actionTitle, action: action).disabled(state == .granted)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch state {
        case .granted: return String(localized: "已授权")
        case .denied: return String(localized: "未授权")
        // Optional permissions nobody has asked for yet are not failures.
        case .notDetermined: return String(localized: "尚未请求")
        case .unavailable(let message): return message
        }
    }

    private var statusColor: Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unavailable: return .secondary
        }
    }
}
