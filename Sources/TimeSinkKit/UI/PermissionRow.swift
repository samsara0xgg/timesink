import SwiftUI

/// Shared permission status view, used both as a compact settings-page row
/// (`compact == true`, mirrors the old `accessibilityRow`/`chromeRow`) and as
/// an onboarding card (`compact == false`, mirrors the old `PermissionCard`).
/// Status color/text are derived from `state` in one place so callers never
/// need to branch on the underlying OSStatus/Bool themselves.
struct PermissionRow: View {
    let title: String
    var explanation: String? = nil
    let state: PermissionState
    var actionTitle = String(localized: "去授权")
    let action: () -> Void
    var compact = true

    var body: some View {
        if compact {
            HStack {
                statusDot
                Text(title)
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
                Button(actionTitle, action: action)
                    .disabled(state == .granted)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    statusDot
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                if let explanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(actionTitle, action: action)
                    .disabled(state == .granted)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusText: String {
        switch state {
        case .granted: return String(localized: "已授权")
        case .denied, .notDetermined: return String(localized: "未授权")
        case .unavailable(let message): return message
        }
    }

    private var statusColor: Color {
        switch state {
        case .granted: return .green
        case .denied, .notDetermined: return .red
        case .unavailable: return .secondary
        }
    }
}
