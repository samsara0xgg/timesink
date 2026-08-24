import Foundation

/// Parses the bundled `seed_domains.csv` resource and imports it into
/// `CategoryStore` on first run (or after a version bump).
///
/// The CSV's first line is a `# version: N` comment; `importIfNeeded` compares
/// `N` against the `seedVersion` setting and only imports (then bumps the
/// setting) when the bundled version is newer.
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

    /// Imports the bundled seed CSV into `categoryStore` if its `# version:`
    /// header is newer than the stored `seedVersion` setting, then updates
    /// the setting so subsequent launches skip the import.
    @MainActor
    public static func importIfNeeded(categoryStore: CategoryStore, settings: SettingsStore) {
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
}
