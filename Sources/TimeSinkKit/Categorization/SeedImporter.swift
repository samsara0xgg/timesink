import Foundation

/// Parses the bundled `seed_domains.csv` and `seed_overlay.csv` resources and
/// imports each into `CategoryStore` on first run (or after its own version
/// bump). The two imports are independently version-gated and both run on
/// every call to `importIfNeeded` -- see that function's doc comment for why.
///
/// Each CSV's first line is a `# version: N` comment; the corresponding
/// `import*IfNeeded` compares `N` against its own settings key and only
/// imports (then bumps the setting) when the bundled version is newer.
public enum SeedImporter {
    private static let versionSettingKey = "seedVersion"

    /// Parses `domain,categoryID` rows, skipping `#`-comment lines and any
    /// line that isn't exactly two comma-separated columns. Rows whose
    /// `categoryID` isn't one of `Taxonomy.categories`'s ids are dropped.
    public static func parseCSV(_ text: String) -> [(domain: String, categoryID: String)] {
        let validIDs = Set(Taxonomy.categories.map(\.id))
        var pairs: [(domain: String, categoryID: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count == 2 else { continue }
            let domain = String(columns[0])
            let categoryID = String(columns[1])
            guard validIDs.contains(categoryID) else { continue }
            pairs.append((domain: domain, categoryID: categoryID))
        }
        return pairs
    }

    /// What the bundled data maps `domain` to, the curated overlay first:
    /// the default a removed user correction falls back to.
    static func shippedDomain(_ domain: String) -> (categoryID: String, source: String)? {
        for (resource, source) in [("seed_overlay", "curated"), ("seed_domains", "seed")] {
            guard let url = Bundle.module.url(forResource: resource, withExtension: "csv"),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let pair = parseCSV(text).first(where: { $0.domain == domain }) else { continue }
            return (pair.categoryID, source)
        }
        return nil
    }

    /// Reads `# version: N` from the first line of `text`. Returns `nil` if
    /// the line is missing or malformed.
    private static func parseVersion(_ text: String) -> Int? {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let prefix = "# version:"
        guard firstLine.hasPrefix(prefix) else { return nil }
        let numberPart = String(firstLine.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return Int(numberPart)
    }

    /// Runs the main-seed and curated-overlay imports. Each is independently
    /// version-gated (`seedVersion` vs. `curatedSeedVersion`), so this must
    /// call both unconditionally rather than nesting the overlay inside the
    /// main seed's early returns -- on any install where the main seed is
    /// already at its bundled version (i.e. every launch after the first),
    /// a nested call would never run and the overlay would never ship.
    @MainActor
    public static func importIfNeeded(categoryStore: CategoryStore, settings: SettingsStore) {
        importMainSeedIfNeeded(categoryStore: categoryStore, settings: settings)
        importOverlayIfNeeded(categoryStore: categoryStore, settings: settings)
    }

    /// Imports the bundled seed CSV into `categoryStore` if its `# version:`
    /// header is newer than the stored `seedVersion` setting, then updates
    /// the setting so subsequent launches skip the import.
    @MainActor
    private static func importMainSeedIfNeeded(categoryStore: CategoryStore, settings: SettingsStore) {
        guard let url = Bundle.module.url(forResource: "seed_domains", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        guard let bundledVersion = parseVersion(text) else { return }
        let currentVersion = settings.get(versionSettingKey).flatMap(Int.init) ?? 0
        guard bundledVersion > currentVersion else { return }

        let pairs = parseCSV(text)
        do {
            try categoryStore.importSeedDomains(pairs)
            settings.set(versionSettingKey, String(bundledVersion))
        } catch {
            // Leave seedVersion unset so the import is retried next launch.
        }
    }

    private static let overlayVersionSettingKey = "curatedSeedVersion"

    /// Same version-gated import as the main seed, for `seed_overlay.csv`
    /// (curated dev/writing/productivity domains the WhoTracks.me data lacks).
    @MainActor
    private static func importOverlayIfNeeded(categoryStore: CategoryStore, settings: SettingsStore) {
        guard let url = Bundle.module.url(forResource: "seed_overlay", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let bundledVersion = parseVersion(text) else { return }
        let currentVersion = settings.get(overlayVersionSettingKey).flatMap(Int.init) ?? 0
        guard bundledVersion > currentVersion else { return }
        do {
            try categoryStore.importCuratedDomains(parseCSV(text))
            settings.set(overlayVersionSettingKey, String(bundledVersion))
        } catch {
            // Leave the version unset so the import retries next launch.
        }
    }
}
