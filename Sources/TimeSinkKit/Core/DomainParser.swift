import Foundation

public enum DomainParser {
    public static func domain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https",
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}
