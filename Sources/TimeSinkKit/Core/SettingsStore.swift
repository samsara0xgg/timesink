import Foundation
import GRDB

public final class SettingsStore: Sendable {
    let writer: any DatabaseWriter

    private static let idleThresholdKey = "idleThreshold"
    private static let llmEnabledKey = "llmEnabled"
    private static let llmEndpointKey = "llmEndpoint"
    private static let llmModelKey = "llmModel"

    private static let defaultIdleThreshold: TimeInterval = 180
    private static let defaultLLMEnabled = false
    private static let defaultLLMEndpoint = "https://api.openai.com/v1"
    private static let defaultLLMModel = "gpt-4o-mini"

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Reads a raw setting value. Swallows any error and returns nil (not fatal).
    public func get(_ key: String) -> String? {
        try? writer.read { db in
            try SettingRow.fetchOne(db, key: key)?.value
        }
    }

    /// Writes a raw setting value. Swallows any error.
    public func set(_ key: String, _ value: String) {
        _ = try? writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO setting (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    public var idleThreshold: TimeInterval {
        self.get(Self.idleThresholdKey).flatMap(TimeInterval.init) ?? Self.defaultIdleThreshold
    }

    public func setIdleThreshold(_ v: TimeInterval) {
        set(Self.idleThresholdKey, String(v))
    }

    public var llmEnabled: Bool {
        self.get(Self.llmEnabledKey).flatMap { $0 == "true" } ?? Self.defaultLLMEnabled
    }

    public func setLLMEnabled(_ v: Bool) {
        set(Self.llmEnabledKey, v ? "true" : "false")
    }

    public var llmEndpoint: String {
        self.get(Self.llmEndpointKey) ?? Self.defaultLLMEndpoint
    }

    public var llmModel: String {
        self.get(Self.llmModelKey) ?? Self.defaultLLMModel
    }

    public func setLLMEndpoint(_ v: String) {
        set(Self.llmEndpointKey, v)
    }

    public func setLLMModel(_ v: String) {
        set(Self.llmModelKey, v)
    }
}
