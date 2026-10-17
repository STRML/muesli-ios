import XCTest
import SQLite3
@testable import Muesli

/// The normalized-column backfill runs once per schema version, not on every process start.
///
/// A process start is simulated by opening the same database file through a different path string: the store keeps
/// a per-process cache keyed by path, so a symlinked directory is a fresh "process" over the same file. Update
/// counts come from SQL triggers placed in the fixture, so the tests observe what the store did to the file rather
/// than a counter inside the store.
final class SharedStoreBackfillTests: XCTestCase {
    private let currentVersion = 7

    // MARK: Fixture content

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    struct LegacyRows {
        var results: [(id: String, requestID: String, createdAt: Double, payload: Data)] = []
        var sessions: [(id: String, requestID: String?, kind: String, phase: String, createdAt: Double, payload: Data)] = []
        var transcripts: [(id: String, sessionID: String, createdAt: Double, engine: String, payload: Data)] = []
        var words: [(id: String, word: String, createdAt: Double, isEnabled: Int, payload: Data)] = []
    }

    /// Rows a v1 store could hold, including a payload that cannot be decoded in every table.
    private func legacyRows() throws -> LegacyRows {
        let encoder = JSONEncoder()
        var rows = LegacyRows()
        let garbage = Data("not json at all".utf8)

        let result = DictationResult(
            id: uuid(1), requestID: uuid(2), sessionID: uuid(3), text: "legacy dictation",
            createdAt: Date(timeIntervalSince1970: 10), engineIdentifier: "parakeet-v3"
        )
        rows.results.append((uuid(1).uuidString, uuid(2).uuidString, 10, try encoder.encode(result)))
        rows.results.append((uuid(4).uuidString, uuid(5).uuidString, 11, garbage))

        let session = RecordingSession(
            id: uuid(3), requestID: uuid(2), kind: .meeting, title: "Legacy meeting",
            createdAt: Date(timeIntervalSince1970: 20), startedAt: Date(timeIntervalSince1970: 19),
            phase: .completed, audioFileName: "legacy.wav", keepsAudioRecording: true,
            engineIdentifier: "parakeet-v3"
        )
        rows.sessions.append((uuid(3).uuidString, uuid(2).uuidString, "meeting", "completed", 20, try encoder.encode(session)))
        rows.sessions.append((uuid(6).uuidString, nil, "quickDictation", "completed", 21, garbage))

        let transcript = Transcript(
            id: uuid(7), sessionID: uuid(3), text: "legacy transcript",
            createdAt: Date(timeIntervalSince1970: 30), engineIdentifier: "parakeet-v3",
            summaryText: "Legacy notes", summaryState: .completed,
            summaryBackend: "openrouter", summaryModel: "gpt-5.5"
        )
        rows.transcripts.append((uuid(7).uuidString, uuid(3).uuidString, 30, "parakeet-v3", try encoder.encode(transcript)))
        rows.transcripts.append((uuid(8).uuidString, uuid(6).uuidString, 31, "whisper", garbage))

        let word = CustomWord(
            id: uuid(9), word: "muesli", replacement: "Muesli", matchingThreshold: 0.9,
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let disabled = CustomWord(
            id: uuid(10), word: "off", createdAt: Date(timeIntervalSince1970: 41), isEnabled: false
        )
        rows.words.append((uuid(9).uuidString, "muesli", 40, 1, try encoder.encode(word)))
        rows.words.append((uuid(10).uuidString, "off", 41, 0, try encoder.encode(disabled)))
        rows.words.append((uuid(11).uuidString, "broken", 42, 1, garbage))
        return rows
    }

    // MARK: Tests

    // Row S1: the rows a legacy store holds end up with exactly the content the always-run backfill produced.
    // The golden dump was captured from the unmodified code on fork/main, before this change.
    func testLegacyStoreBackfillsToTheContentTheOldCodeProduced() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)

        _ = try openAsNewProcess(real).pendingRequest()

        XCTAssertEqual(try dumpBackfilledTables(in: real), Self.goldenLegacyDump)
    }

    // Row S2: running the backfill again over a finished store changes nothing, which is what makes skipping it safe.
    func testRunningTheBackfillAgainLeavesTheContentIdentical() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        _ = try openAsNewProcess(real).pendingRequest()
        let afterFirst = try dumpBackfilledTables(in: real)

        try rawExec("PRAGMA user_version = 1", in: real)
        _ = try openAsNewProcess(real).pendingRequest()

        XCTAssertEqual(try dumpBackfilledTables(in: real), afterFirst)
    }

    // Row S3: a fresh install has nothing to backfill and records the current version.
    func testFreshInstallRecordsTheCurrentVersionAndUpdatesNothing() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        let store = openAsNewProcess(real)
        XCTAssertNil(try store.pendingRequest())
        XCTAssertEqual(try userVersion(in: real), currentVersion)

        try installUpdateLog(in: real)
        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(try updateCount(in: real), 0)
    }

    // Row S4: an old store with data backfills once, and the second launch runs no UPDATE at all.
    func testOldStoreBackfillsOnceAndTheSecondLaunchUpdatesNothing() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        try installUpdateLog(in: real)

        _ = try openAsNewProcess(real).pendingRequest()
        let firstLaunch = try updateCount(in: real)
        XCTAssertEqual(firstLaunch, 9, "one UPDATE per legacy row: 2 results, 2 sessions, 2 transcripts, 3 words")
        XCTAssertEqual(try userVersion(in: real), currentVersion)

        _ = try openAsNewProcess(real).pendingRequest()
        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(try updateCount(in: real), firstLaunch)
    }

    // Row S5: the second launch does not write the database file at all, not even the version number.
    func testSecondLaunchLeavesTheDatabaseFileByteForByteUnchanged() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        _ = try openAsNewProcess(real).pendingRequest()
        let before = try Data(contentsOf: real.appendingPathComponent("Muesli.sqlite"))

        _ = try openAsNewProcess(real).pendingRequest()

        let after = try Data(contentsOf: real.appendingPathComponent("Muesli.sqlite"))
        XCTAssertEqual(before, after)
        let walSize = (try? FileManager.default.attributesOfItem(
            atPath: real.appendingPathComponent("Muesli.sqlite-wal").path
        )[.size] as? Int) ?? 0
        XCTAssertEqual(walSize, 0, "nothing left in the write-ahead log")
    }

    // Row S6: an install on the previous version (6) runs the backfill once more and moves to the new version.
    func testStoreOnThePreviousVersionBackfillsOnceMore() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        _ = try openAsNewProcess(real).pendingRequest()
        try rawExec("PRAGMA user_version = 6", in: real)
        try installUpdateLog(in: real)

        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(try updateCount(in: real), 9)
        XCTAssertEqual(try userVersion(in: real), currentVersion)

        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(try updateCount(in: real), 9)
    }

    // Row S7: a store written by a newer build is neither backfilled nor downgraded.
    func testStoreNewerThanTheCodeIsNotDowngradedOrBackfilled() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        _ = try openAsNewProcess(real).pendingRequest()
        try rawExec("PRAGMA user_version = 99", in: real)
        try installUpdateLog(in: real)

        _ = try openAsNewProcess(real).pendingRequest()
        _ = try openAsNewProcess(real).pendingRequest()

        XCTAssertEqual(try updateCount(in: real), 0)
        XCTAssertEqual(try userVersion(in: real), 99)
    }

    // Row S8: a backfill that fails part way rolls everything back, leaves the version alone, and runs again.
    func testInterruptedBackfillRollsBackAndRunsAgainNextTime() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        // Results and sessions update first; the transcript update fails.
        try rawExec(
            "CREATE TRIGGER interrupt_backfill BEFORE UPDATE ON transcripts BEGIN SELECT RAISE(ABORT, 'interrupted'); END",
            in: real
        )

        XCTAssertThrowsError(try openAsNewProcess(real).pendingRequest())
        XCTAssertEqual(try userVersion(in: real), 1)
        XCTAssertEqual(
            try rawInt("SELECT COUNT(*) FROM result_history WHERE text <> ''", in: real), 0,
            "the result updates that came before the failure were rolled back"
        )
        XCTAssertEqual(try rawInt("SELECT COUNT(*) FROM recording_sessions WHERE title IS NOT NULL", in: real), 0)

        try rawExec("DROP TRIGGER interrupt_backfill", in: real)
        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(try userVersion(in: real), currentVersion)
        XCTAssertEqual(try dumpBackfilledTables(in: real), Self.goldenLegacyDump)
    }

    // Row S9: a payload that cannot be decoded is backfilled from the row's own columns, once, without a crash.
    func testUndecodablePayloadRowsAreFilledFromTheirColumnsOnceAndNeverLoop() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        try installUpdateLog(in: real)

        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(
            try rawString("SELECT kind FROM recording_sessions WHERE id = '\(uuid(6).uuidString)'", in: real),
            "quickDictation"
        )
        XCTAssertEqual(
            try rawInt("SELECT matching_threshold * 100 FROM custom_words WHERE id = '\(uuid(11).uuidString)'", in: real),
            85
        )
        let afterFirst = try updateCount(in: real)
        _ = try openAsNewProcess(real).pendingRequest()
        XCTAssertEqual(try updateCount(in: real), afterFirst)
    }

    // Row S10: an empty legacy store (tables, no rows) moves to the current version without an UPDATE.
    func testEmptyLegacyStoreMovesToTheCurrentVersion() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: LegacyRows(), userVersion: 1)
        try installUpdateLog(in: real)

        XCTAssertNil(try openAsNewProcess(real).pendingRequest())
        XCTAssertEqual(try userVersion(in: real), currentVersion)
        XCTAssertEqual(try updateCount(in: real), 0)
    }

    // Row S11: the other process (the keyboard) finishes the backfill while this one waits for the write lock.
    // This one must find the version current once it has the lock, and run no UPDATE of its own.
    func testProcessThatLosesTheRaceFindsTheBackfillDoneAndSkipsIt() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        // Bring the schema fully up to date, then put the version back so the next open wants the backfill.
        _ = try openAsNewProcess(real).pendingRequest()
        try rawExec("PRAGMA user_version = 1", in: real)
        try installUpdateLog(in: real)

        let other = try openRaw(in: real)
        defer { sqlite3_close(other) }
        XCTAssertEqual(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let store = openAsNewProcess(real)
        let finished = expectation(description: "store initialized")
        nonisolated(unsafe) var thrown: Error?
        DispatchQueue.global().async {
            do { _ = try store.pendingRequest() } catch { thrown = error }
            finished.fulfill()
        }
        // The other process completes while the store waits on its lock.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sqlite3_exec(other, "PRAGMA user_version = \(currentVersion); COMMIT", nil, nil, nil), SQLITE_OK)

        wait(for: [finished], timeout: 20)
        XCTAssertNil(thrown)
        XCTAssertEqual(try updateCount(in: real), 0)
        XCTAssertEqual(try userVersion(in: real), currentVersion)
    }

    // Row S12: two processes start on the same old store at the same moment. Between them the backfill runs once.
    func testTwoProcessesStartingTogetherBackfillExactlyOnce() throws {
        let real = try makeDirectory()
        defer { trash(real) }
        try createLegacyDatabase(in: real, rows: try legacyRows(), userVersion: 1)
        try installUpdateLog(in: real)
        let first = openAsNewProcess(real)
        let second = openAsNewProcess(real)

        let group = DispatchGroup()
        nonisolated(unsafe) var errors: [Error] = []
        let errorLock = NSLock()
        for store in [first, second] {
            group.enter()
            DispatchQueue.global().async {
                do { _ = try store.pendingRequest() } catch {
                    errorLock.lock(); errors.append(error); errorLock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(try updateCount(in: real), 9)
        XCTAssertEqual(try userVersion(in: real), currentVersion)
    }
}

// MARK: - Helpers

private extension SharedStoreBackfillTests {
    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func trash(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A store over `real` that the per-process cache has never seen: the same file through a fresh symlink.
    func openAsNewProcess(_ real: URL) -> SharedStore {
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-backfill-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        return SharedStore(containerURL: link)
    }

    func openRaw(in directory: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("Muesli.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else {
            throw FixtureError("open failed")
        }
        sqlite3_busy_timeout(database, 5000)
        return database
    }

    func rawExec(_ sql: String, in directory: URL) throws {
        let database = try openRaw(in: directory)
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw FixtureError(text)
        }
    }

    func rawRows(_ sql: String, in directory: URL) throws -> [[String]] {
        let database = try openRaw(in: directory)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FixtureError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL:
                    row.append("NULL")
                case SQLITE_FLOAT:
                    row.append(String(format: "%.6f", sqlite3_column_double(statement, column)))
                case SQLITE_INTEGER:
                    row.append(String(sqlite3_column_int64(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row.append("blob(\(count))")
                default:
                    row.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                }
            }
            rows.append(row)
        }
        return rows
    }

    func rawInt(_ sql: String, in directory: URL) throws -> Int {
        Int(try rawRows(sql, in: directory).first?.first.flatMap(Double.init) ?? -1)
    }

    func rawString(_ sql: String, in directory: URL) throws -> String? {
        try rawRows(sql, in: directory).first?.first
    }

    func userVersion(in directory: URL) throws -> Int {
        try rawInt("PRAGMA user_version", in: directory)
    }

    /// Every UPDATE the store runs on a backfilled table inserts a row here.
    @discardableResult
    func installUpdateLog(in directory: URL) throws -> Bool {
        var statements = ["CREATE TABLE IF NOT EXISTS test_update_log (source TEXT)"]
        for table in ["result_history", "recording_sessions", "transcripts", "custom_words"] {
            statements.append(
                "CREATE TRIGGER IF NOT EXISTS log_\(table) AFTER UPDATE ON \(table) BEGIN INSERT INTO test_update_log VALUES ('\(table)'); END"
            )
        }
        try rawExec(statements.joined(separator: "; "), in: directory)
        return true
    }

    func updateCount(in directory: URL) throws -> Int {
        try rawInt("SELECT COUNT(*) FROM test_update_log", in: directory)
    }

    /// Every column of the four backfilled tables, sorted by primary key, as text.
    func dumpBackfilledTables(in directory: URL) throws -> String {
        var lines: [String] = []
        for table in ["result_history", "recording_sessions", "transcripts", "custom_words"] {
            let columns = try rawRows("PRAGMA table_info(\(table))", in: directory).map { $0[1] }.sorted()
            let list = columns.joined(separator: ", ")
            lines.append("== \(table): \(list)")
            for row in try rawRows("SELECT \(list) FROM \(table) ORDER BY id", in: directory) {
                lines.append(row.joined(separator: " | "))
            }
        }
        return lines.joined(separator: "\n")
    }

    func createLegacyDatabase(in directory: URL, rows: LegacyRows, userVersion: Int) throws {
        let database = try openRaw(in: directory)
        defer { sqlite3_close(database) }
        // Stores in the field are always in WAL mode. Switching a rollback-journal file to WAL while another
        // connection is open is a lock fight that has nothing to do with the backfill, so the fixture starts in WAL.
        try execute(
            """
            PRAGMA journal_mode = WAL;
            CREATE TABLE key_values (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE result_pickups (request_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE result_history (id TEXT NOT NULL, request_id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE recording_sessions (id TEXT PRIMARY KEY NOT NULL, request_id TEXT UNIQUE, kind TEXT NOT NULL, phase TEXT NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE transcripts (id TEXT PRIMARY KEY NOT NULL, session_id TEXT UNIQUE NOT NULL, created_at REAL NOT NULL, engine_identifier TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE custom_words (id TEXT PRIMARY KEY NOT NULL, word TEXT NOT NULL, created_at REAL NOT NULL, is_enabled INTEGER NOT NULL, payload BLOB NOT NULL);
            PRAGMA user_version = \(userVersion);
            """,
            database
        )
        for row in rows.results {
            try insert("INSERT INTO result_history (id, request_id, created_at, payload) VALUES (?, ?, ?, ?)",
                       database, [.text(row.id), .text(row.requestID), .real(row.createdAt), .blob(row.payload)])
        }
        for row in rows.sessions {
            try insert("INSERT INTO recording_sessions (id, request_id, kind, phase, created_at, payload) VALUES (?, ?, ?, ?, ?, ?)",
                       database, [.text(row.id), .text(row.requestID), .text(row.kind), .text(row.phase), .real(row.createdAt), .blob(row.payload)])
        }
        for row in rows.transcripts {
            try insert("INSERT INTO transcripts (id, session_id, created_at, engine_identifier, payload) VALUES (?, ?, ?, ?, ?)",
                       database, [.text(row.id), .text(row.sessionID), .real(row.createdAt), .text(row.engine), .blob(row.payload)])
        }
        for row in rows.words {
            try insert("INSERT INTO custom_words (id, word, created_at, is_enabled, payload) VALUES (?, ?, ?, ?, ?)",
                       database, [.text(row.id), .text(row.word), .real(row.createdAt), .integer(row.isEnabled), .blob(row.payload)])
        }
    }

    enum Bound {
        case text(String?)
        case real(Double)
        case integer(Int)
        case blob(Data)
    }

    func execute(_ sql: String, _ database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw FixtureError(text)
        }
    }

    func insert(_ sql: String, _ database: OpaquePointer, _ values: [Bound]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FixtureError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                if let text { sqlite3_bind_text(statement, position, text, -1, transient) } else { sqlite3_bind_null(statement, position) }
            case .real(let number):
                sqlite3_bind_double(statement, position, number)
            case .integer(let number):
                sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension SharedStoreBackfillTests {
    /// Captured by running `dumpBackfilledTables` against the unmodified store code on fork/main.
    static let goldenLegacyDump = """
== result_history: cloud_change_tag, cloud_record_name, cloud_system_fields, created_at, deleted_at, engine_identifier, id, last_synced_at, payload, request_id, session_id, sync_dirty, text, updated_at
NULL | 00000000-0000-0000-0000-000000000001 | NULL | 10.000000 | NULL | parakeet-v3 | 00000000-0000-0000-0000-000000000001 | NULL | blob(229) | 00000000-0000-0000-0000-000000000002 | 00000000-0000-0000-0000-000000000003 | 1 | legacy dictation | 10.000000
NULL | 00000000-0000-0000-0000-000000000004 | NULL | 11.000000 | NULL |  | 00000000-0000-0000-0000-000000000004 | NULL | blob(15) | 00000000-0000-0000-0000-000000000005 | NULL | 1 |  | 11.000000
== recording_sessions: audio_file_name, cloud_change_tag, cloud_record_name, cloud_system_fields, created_at, deleted_at, ended_at, engine_identifier, error_message, id, keeps_audio_recording, kind, last_synced_at, manual_notes, manual_notes_updated_at, payload, phase, request_id, started_at, sync_dirty, title, transcript_id, updated_at
legacy.wav | NULL | 00000000-0000-0000-0000-000000000003 | NULL | 20.000000 | NULL | NULL | parakeet-v3 | NULL | 00000000-0000-0000-0000-000000000003 | 1 | meeting | NULL | NULL | 0.000000 | blob(421) | completed | 00000000-0000-0000-0000-000000000002 | 19.000000 | 1 | Legacy meeting | NULL | 20.000000
NULL | NULL | 00000000-0000-0000-0000-000000000006 | NULL | 21.000000 | NULL | NULL | NULL | NULL | 00000000-0000-0000-0000-000000000006 | 0 | quickDictation | NULL | NULL | 0.000000 | blob(15) | completed | NULL | NULL | 1 | NULL | NULL | 21.000000
== transcripts: cloud_change_tag, cloud_record_name, created_at, deleted_at, diarization_error_message, diarization_state, engine_identifier, id, last_synced_at, payload, session_id, speaker_transcript, summary_backend, summary_error_message, summary_model, summary_state, summary_text, sync_dirty, text, updated_at
NULL | 00000000-0000-0000-0000-000000000007 | 30.000000 | NULL | NULL | notStarted | parakeet-v3 | 00000000-0000-0000-0000-000000000007 | NULL | blob(322) | 00000000-0000-0000-0000-000000000003 | NULL | openrouter | NULL | gpt-5.5 | notStarted | Legacy notes | 1 | legacy transcript | 30.000000
NULL | 00000000-0000-0000-0000-000000000008 | 31.000000 | NULL | NULL | notStarted | whisper | 00000000-0000-0000-0000-000000000008 | NULL | blob(15) | 00000000-0000-0000-0000-000000000006 | NULL | NULL | NULL | NULL | notStarted | NULL | 1 |  | 31.000000
== custom_words: cloud_change_tag, cloud_record_name, created_at, deleted_at, id, is_enabled, last_synced_at, matching_threshold, payload, replacement, sync_dirty, updated_at, word
NULL | 00000000-0000-0000-0000-000000000009 | 40.000000 | NULL | 00000000-0000-0000-0000-000000000009 | 1 | NULL | 0.900000 | blob(151) | Muesli | 1 | 40.000000 | muesli
NULL | 00000000-0000-0000-0000-000000000010 | 41.000000 | NULL | 00000000-0000-0000-0000-000000000010 | 0 | NULL | 0.850000 | blob(127) | NULL | 1 | 41.000000 | off
NULL | 00000000-0000-0000-0000-000000000011 | 42.000000 | NULL | 00000000-0000-0000-0000-000000000011 | 1 | NULL | 0.850000 | blob(15) | NULL | 1 | 42.000000 | broken
"""
}
