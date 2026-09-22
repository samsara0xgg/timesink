import Foundation

/// A span's `document`: what the front window is *on* -- a terminal's working
/// directory, an editor's file, or an AI chat app's conversation name.
/// Path-shaped documents arrive as `file://` URLs from
/// `kAXDocumentAttribute`; conversation names arrive as plain text. These
/// helpers are the one place that tells the two apart, shared by the sampler
/// (which drops a document that says nothing) and the activity list (which
/// has to display both kinds).
public enum DocumentIdentity {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// The filesystem path a document denotes, without a trailing slash, or
    /// nil when it denotes no path -- a conversation name, or a non-file URL
    /// such as the `app://-/index.html` ChatGPT's own shell reports.
    public static func path(of document: String) -> String? {
        let raw: String
        if document.hasPrefix("file://") {
            guard let url = URL(string: document) else { return nil }
            raw = url.path
        } else if document.hasPrefix("/") {
            raw = document
        } else {
            return nil
        }
        guard !raw.isEmpty else { return nil }
        return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// True when the document is a web page. A browser publishes the page
    /// URL as its window document -- measured on Chrome 2026-09-22, which
    /// answers `kAXURL` with the front tab's address -- and that is already
    /// what `Span.url`/`Span.domain` carry, grouped by domain and by URL
    /// entity. Taking it as a document instead would replace one row per
    /// site with one row per page, so a web page is never a document.
    public static func isWebPage(_ document: String) -> Bool {
        document.hasPrefix("http://") || document.hasPrefix("https://")
    }

    /// True when the document says nothing more specific than the user's home
    /// directory -- what a terminal reports when the shell in front of it
    /// never emitted a working directory of its own.
    public static func isHome(_ document: String) -> Bool {
        path(of: document) == homePath
    }

    /// Display form: a path shortened to `~/Projects/jarvis`, anything else
    /// (a conversation name) verbatim.
    public static func label(for document: String) -> String {
        guard let path = path(of: document) else { return document }
        guard path == homePath || path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
