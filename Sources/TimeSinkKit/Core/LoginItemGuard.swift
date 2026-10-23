import Foundation
import ServiceManagement

/// The login item: what he asked for against what macOS reports. A gap of 20
/// hours (10-02/03) came from the item being switched off after reboots with
/// nothing noticing.
public enum LoginItemGuard {
    public static let wantedKey = "loginItemWanted"

    /// `warn`: he wants the item and macOS says it is off. `store`: the wish to
    /// persist now -- an install that predates the key with the item on counts
    /// as wanting it; with the item off and no key there is no wish to guard.
    public static func decide(stored: String?, status: SMAppService.Status) -> (warn: Bool, store: Bool?) {
        let wanted = stored.map { $0 == "true" } ?? (status == .enabled)
        let off = status == .notRegistered || status == .requiresApproval
        return (wanted && off, stored == nil && status == .enabled ? true : nil)
    }
}
