import GRDB
import XCTest
@testable import TimeSinkKit

/// Migration v7's `span.document`: what a window is on (a working directory,
/// an open file, an AI chat conversation) has to split spans, survive the
/// migration of an existing database, and drive the activity list's grouping.
final class DocumentIdentityTests: XCTestCase {

    // MARK: - SpanBuilder

    private func documentSample(_ t: TimeInterval, document: String?) -> Sample {
        Sample(timestamp: ts(t), appBundleID: "com.mitchellh.ghostty", appName: "Ghostty",
               windowTitle: "cc", url: nil, document: document)
    }

    func testDocumentChangeSplitsSpan() {
        let builder = SpanBuilder()
        _ = builder.ingest(documentSample(0, document: "file:///Users/a/Projects/jarvis/"))
        let closed = builder.ingest(documentSample(1, document: "file:///Users/a/Projects/hermes/"))
        XCTAssertEqual(closed?.document, "file:///Users/a/Projects/jarvis/")
        XCTAssertEqual(closed?.end, ts(1))
        XCTAssertEqual(builder.current?.document, "file:///Users/a/Projects/hermes/")
        XCTAssertEqual(builder.current?.start, ts(1))
    }

    func testSameDocumentExtendsSpan() {
        let builder = SpanBuilder()
        _ = builder.ingest(documentSample(0, document: "会话 A"))
        XCTAssertNil(builder.ingest(documentSample(1, document: "会话 A")))
        XCTAssertEqual(builder.current?.duration, 2)
    }

    /// The title is unchanged across both samples, so only the document can
    /// be what splits them -- a ChatGPT window whose title is forever
    /// "ChatGPT" while the conversation underneath changes.
    func testConversationChangeSplitsDespiteConstantTitle() {
        let builder = SpanBuilder()
        let chat = { (t: TimeInterval, session: String) in
            Sample(timestamp: ts(t), appBundleID: "com.openai.codex", appName: "ChatGPT",
                   windowTitle: "ChatGPT", url: nil, document: session)
        }
        _ = builder.ingest(chat(0, "检查今日未完成任务"))
        let closed = builder.ingest(chat(1, "为 Hermes agent 选择最佳 LLM 模型"))
        XCTAssertEqual(closed?.document, "检查今日未完成任务")
        XCTAssertEqual(builder.current?.document, "为 Hermes agent 选择最佳 LLM 模型")
    }

    func testNilDocumentStillExtends() {
        let builder = SpanBuilder()
        _ = builder.ingest(documentSample(0, document: nil))
        XCTAssertNil(builder.ingest(documentSample(1, document: nil)))
        XCTAssertNil(builder.current?.document)
    }

    // MARK: - Migration v7

    /// A database that already ran v1..v6 must gain the column with every
    /// pre-existing row reading nil, not fail and not backfill anything.
    func testMigrationV7LeavesExistingRowsNil() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO span (start, \"end\", appBundleID, appName, title, url, domain) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [ts(0), ts(60), "com.mitchellh.ghostty", "Ghostty", "cc", nil, nil]
            )
        }
        try AppDatabase.migrator.migrate(queue)

        let spans = try SpanStore(queue).spans(overlapping: DateInterval(start: ts(-1), end: ts(61)))
        XCTAssertEqual(spans.count, 1)
        XCTAssertNil(spans[0].document)
        XCTAssertEqual(spans[0].title, "cc")
    }

    func testDocumentRoundTripsThroughTheStore() throws {
        let store = try SpanStore(AppDatabase.openInMemory())
        try store.insert(Span(start: ts(0), end: ts(60), appBundleID: "com.openai.codex",
                              appName: "ChatGPT", title: "ChatGPT", url: nil, domain: nil,
                              document: "检查今日未完成任务"))
        let spans = try store.spans(overlapping: DateInterval(start: ts(-1), end: ts(61)))
        XCTAssertEqual(spans.first?.document, "检查今日未完成任务")
    }

    /// v7 also seeds the app categories v1 never had. An existing database
    /// runs v1's seed loop before that list grew, so only the migration can
    /// deliver them -- and it must not clobber a user's own override.
    func testMigrationV7SeedsNewAppCategoriesWithoutClobbering() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        // v1 seeds whatever `builtinApps` says TODAY, so a database stopped
        // at v6 in this process already has the v7 rows. Allen's real
        // database ran v1 when the list was shorter, so reproduce that:
        // drop the rows v1 could not have known about, and leave one
        // override behind that the migration must not overwrite.
        try queue.write { db in
            for app in Taxonomy.v7Apps {
                try db.execute(sql: "DELETE FROM appCategory WHERE bundleID = ?", arguments: [app.bundleID])
            }
            try db.execute(
                sql: "INSERT INTO appCategory (bundleID, categoryID, source) VALUES ('com.openai.codex', 'entertainment', 'user')"
            )
        }
        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            for app in Taxonomy.v7Apps where app.bundleID != "com.openai.codex" {
                let row = try Row.fetchOne(db, sql: "SELECT categoryID FROM appCategory WHERE bundleID = ?",
                                           arguments: [app.bundleID])
                XCTAssertEqual(row?["categoryID"], app.categoryID, app.bundleID)
            }
            let kept = try Row.fetchOne(db, sql: "SELECT categoryID, source FROM appCategory WHERE bundleID = 'com.openai.codex'")
            XCTAssertEqual(kept?["categoryID"], "entertainment")
            XCTAssertEqual(kept?["source"], "user")
        }
    }

    // MARK: - DocumentIdentity

    func testPathDocumentsAbbreviateToTilde() {
        let home = DocumentIdentity.homePath
        XCTAssertEqual(DocumentIdentity.label(for: "file://\(home)/Projects/jarvis/"), "~/Projects/jarvis")
        XCTAssertEqual(DocumentIdentity.label(for: "\(home)/Projects/jarvis"), "~/Projects/jarvis")
        XCTAssertEqual(DocumentIdentity.label(for: "file:///Applications"), "/Applications")
    }

    /// A conversation name is not a path and must survive untouched --
    /// including one that happens to start with a slash-free tilde or a dot.
    func testNonPathDocumentsAreVerbatim() {
        XCTAssertEqual(DocumentIdentity.label(for: "检查今日未完成任务"), "检查今日未完成任务")
        XCTAssertEqual(DocumentIdentity.label(for: "cc | 9.22 gptlive"), "cc | 9.22 gptlive")
        XCTAssertNil(DocumentIdentity.path(of: "cc | 9.22 gptlive"))
    }

    /// The sampler keeps a window document only when it names a path. Every
    /// browser-shaped URL must fail that, including Chrome's internal pages,
    /// which is what leaked on 2026-09-22 through an http-only guard.
    func testOnlyPathsQualifyAsWindowDocuments() {
        for url in ["https://www.freecodecamp.org/", "http://localhost:8080/x",
                    "chrome://newtab/", "chrome://downloads/", "about:blank",
                    "app://-/index.html"] {
            XCTAssertNil(DocumentIdentity.path(of: url), url)
        }
        XCTAssertEqual(DocumentIdentity.path(of: "file:///Users/a/Projects/jarvis/"), "/Users/a/Projects/jarvis")
    }

    func testHomeDirectoryIsRecognizedInBothForms() {
        let home = DocumentIdentity.homePath
        XCTAssertTrue(DocumentIdentity.isHome("file://\(home)/"))
        XCTAssertTrue(DocumentIdentity.isHome(home))
        XCTAssertFalse(DocumentIdentity.isHome("file://\(home)/Projects/"))
    }

    // MARK: - Activity list grouping

    private func span(_ app: String, _ name: String, document: String?, seconds: TimeInterval,
                      at offset: TimeInterval = 0) -> CategorizedSpan {
        CategorizedSpan(
            span: Span(start: ts(offset), end: ts(offset + seconds), appBundleID: app, appName: name,
                       title: "cc", url: nil, domain: nil, document: document),
            categoryID: "work"
        )
    }

    func testRowsSplitOneAppByDocument() {
        let home = DocumentIdentity.homePath
        let rows = ActivitiesModel.rows(for: [
            span("com.mitchellh.ghostty", "Ghostty", document: "file://\(home)/Projects/jarvis/", seconds: 120),
            span("com.mitchellh.ghostty", "Ghostty", document: "file://\(home)/Projects/hermes/", seconds: 60, at: 200),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Ghostty / ~/Projects/jarvis")
        XCTAssertEqual(rows[0].seconds, 120)
        XCTAssertEqual(rows[1].label, "Ghostty / ~/Projects/hermes")
        // Reassignment still lands at the only granularity the store has.
        XCTAssertEqual(rows[0].reassignKey, "com.mitchellh.ghostty")
        XCTAssertFalse(rows[0].isDomain)
        XCTAssertTrue(rows[0].isEntity)
    }

    func testRowsWithoutDocumentStillGroupByApp() {
        let rows = ActivitiesModel.rows(for: [
            span("md.obsidian", "Obsidian", document: nil, seconds: 60),
            span("md.obsidian", "Obsidian", document: nil, seconds: 60, at: 100),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "md.obsidian")
        XCTAssertEqual(rows[0].label, "Obsidian")
        XCTAssertFalse(rows[0].isEntity)
    }

    /// Two apps on the same repo are two activities, not one.
    func testSameDocumentInTwoAppsStaysTwoRows() {
        let document = "file://\(DocumentIdentity.homePath)/Projects/jarvis/"
        let rows = ActivitiesModel.rows(for: [
            span("com.mitchellh.ghostty", "Ghostty", document: document, seconds: 120),
            span("com.microsoft.VSCode", "Code", document: document, seconds: 60, at: 200),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.label)), ["Ghostty / ~/Projects/jarvis", "Code / ~/Projects/jarvis"])
    }
}
