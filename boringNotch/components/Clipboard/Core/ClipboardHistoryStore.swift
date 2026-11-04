import CryptoKit
import Foundation
import SQLite3

actor ClipboardHistoryStore {
    struct Statistics: Sendable {
        let itemCount: Int
        let pinnedCount: Int
        let totalBytes: Int64
    }

    private struct ExternalBlob {
        let temporaryURL: URL
        let finalURL: URL
        let fileName: String
    }

    private let databaseURL: URL
    private let blobsDirectory: URL
    private var maximumItemCount: Int
    private var maximumStorageBytes: Int64
    private let inlineBlobThreshold = 1 * 1024 * 1024
    private var database: OpaquePointer?
    private var isInitialized = false

    init(
        baseDirectory: URL,
        maximumItemCount: Int = 500,
        maximumStorageBytes: Int64 = 512 * 1024 * 1024
    ) throws {
        guard maximumItemCount > 0 else { throw ClipboardStoreError.invalidItemLimit(maximumItemCount) }
        guard maximumStorageBytes > 0 else { throw ClipboardStoreError.invalidStorageLimit(maximumStorageBytes) }

        self.databaseURL = baseDirectory.appendingPathComponent("ClipboardHistory.sqlite3")
        self.blobsDirectory = baseDirectory.appendingPathComponent("ClipboardBlobs", isDirectory: true)
        self.maximumItemCount = maximumItemCount
        self.maximumStorageBytes = maximumStorageBytes

        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: blobsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var openedDatabase: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let openedDatabase { sqlite3_close(openedDatabase) }
            throw ClipboardStoreError.openFailed(message)
        }
        database = openedDatabase
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func upsert(
        payload: ClipboardPayload,
        kind: ClipboardContentKind,
        title: String,
        subtitle: String?,
        searchText: String,
        thumbnailData: Data?
    ) throws -> ClipboardHistoryItem {
        try Task.checkCancellation()
        try ensureInitialized()
        guard !payload.items.isEmpty else { throw ClipboardStoreError.emptyPayload }
        guard payload.byteCount <= maximumStorageBytes else {
            throw ClipboardStoreError.itemExceedsStorageLimit(
                itemBytes: payload.byteCount,
                limitBytes: maximumStorageBytes
            )
        }
        let hash = contentHash(for: payload)
        let now = Date()

        if let existingID = try identifier(forContentHash: hash) {
            try Task.checkCancellation()
            try transaction {
                try refreshSecurityScopedBookmarks(payload: payload, historyID: existingID)
                try withStatement(
                    """
                    UPDATE history
                    SET kind = ?, title = ?, subtitle = ?, search_text = ?, last_used_at = ?,
                        thumbnail = COALESCE(?, thumbnail), source_bundle_id = ?
                    WHERE id = ?
                    """
                ) { statement in
                    try bind(kind.rawValue, to: 1, in: statement)
                    try bind(title, to: 2, in: statement)
                    try bind(subtitle, to: 3, in: statement)
                    try bind(searchText, to: 4, in: statement)
                    try bind(now.timeIntervalSince1970, to: 5, in: statement)
                    try bind(thumbnailData, to: 6, in: statement)
                    try bind(payload.sourceBundleIdentifier, to: 7, in: statement)
                    try bind(existingID.uuidString, to: 8, in: statement)
                    try stepDone(statement)
                }
            }
            guard let item = try fetchItem(id: existingID) else {
                throw ClipboardStoreError.itemNotFound(existingID)
            }
            return item
        }

        let id = UUID()
        let byteCount = payload.byteCount
        let typeIdentifiers = payload.typeIdentifiers
        let encodedTypes = try String(
            decoding: JSONEncoder().encode(typeIdentifiers),
            as: UTF8.self
        )
        var stagedBlobs: [ExternalBlob] = []
        var committedBlobURLs: [URL] = []
        var prunedBlobNames: [String] = []

        do {
            for (itemIndex, payloadItem) in payload.items.enumerated() {
                for (representationIndex, representation) in payloadItem.representations.enumerated()
                    where representation.data.count > inlineBlobThreshold {
                    let fileName = "\(id.uuidString)-\(itemIndex)-\(representationIndex)-\(UUID().uuidString).blob"
                    let finalURL = blobsDirectory.appendingPathComponent(fileName, isDirectory: false)
                    let temporaryURL = blobsDirectory.appendingPathComponent(".\(fileName).tmp", isDirectory: false)
                    try representation.data.write(to: temporaryURL, options: [.atomic, .completeFileProtection])
                    stagedBlobs.append(
                        ExternalBlob(
                            temporaryURL: temporaryURL,
                            finalURL: finalURL,
                            fileName: fileName
                        )
                    )
                }
            }

            try Task.checkCancellation()
            try transaction {
                try withStatement(
                    """
                    INSERT INTO history (
                        id, content_hash, kind, title, subtitle, search_text, created_at,
                        last_used_at, is_pinned, byte_count, item_count, type_identifiers,
                        thumbnail, source_bundle_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    """
                ) { statement in
                    try bind(id.uuidString, to: 1, in: statement)
                    try bind(hash, to: 2, in: statement)
                    try bind(kind.rawValue, to: 3, in: statement)
                    try bind(title, to: 4, in: statement)
                    try bind(subtitle, to: 5, in: statement)
                    try bind(searchText, to: 6, in: statement)
                    try bind(now.timeIntervalSince1970, to: 7, in: statement)
                    try bind(now.timeIntervalSince1970, to: 8, in: statement)
                    try bind(byteCount, to: 9, in: statement)
                    try bind(payload.items.count, to: 10, in: statement)
                    try bind(encodedTypes, to: 11, in: statement)
                    try bind(thumbnailData, to: 12, in: statement)
                    try bind(payload.sourceBundleIdentifier, to: 13, in: statement)
                    try stepDone(statement)
                }

                var externalBlobIndex = 0
                for (itemIndex, payloadItem) in payload.items.enumerated() {
                    for (representationIndex, representation) in payloadItem.representations.enumerated() {
                        let isExternal = representation.data.count > inlineBlobThreshold
                        let fileName: String?
                        if isExternal {
                            fileName = stagedBlobs[externalBlobIndex].fileName
                            externalBlobIndex += 1
                        } else {
                            fileName = nil
                        }

                        try withStatement(
                            """
                            INSERT INTO representations (
                                history_id, item_index, representation_index, type_identifier,
                                inline_data, blob_path, byte_count
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """
                        ) { statement in
                            try bind(id.uuidString, to: 1, in: statement)
                            try bind(itemIndex, to: 2, in: statement)
                            try bind(representationIndex, to: 3, in: statement)
                            try bind(representation.typeIdentifier, to: 4, in: statement)
                            try bind(isExternal ? nil : representation.data, to: 5, in: statement)
                            try bind(fileName, to: 6, in: statement)
                            try bind(representation.data.count, to: 7, in: statement)
                            try stepDone(statement)
                        }
                    }
                }

                for blob in stagedBlobs {
                    try FileManager.default.moveItem(at: blob.temporaryURL, to: blob.finalURL)
                    committedBlobURLs.append(blob.finalURL)
                }
                prunedBlobNames = try pruneIfNeeded()
            }
        } catch {
            for blob in stagedBlobs {
                try? FileManager.default.removeItem(at: blob.temporaryURL)
            }
            for url in committedBlobURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        try removeBlobFiles(named: prunedBlobNames)
        guard let item = try fetchItem(id: id) else { throw ClipboardStoreError.itemNotFound(id) }
        return item
    }

    func fetch(query: String = "", limit: Int = 500) throws -> [ClipboardHistoryItem] {
        try ensureInitialized()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        if trimmedQuery.isEmpty {
            sql = """
                SELECT id, kind, title, subtitle, search_text, created_at, last_used_at,
                       is_pinned, byte_count, item_count, type_identifiers, thumbnail, source_bundle_id
                FROM history
                ORDER BY is_pinned DESC, last_used_at DESC
                LIMIT ?
                """
        } else {
            sql = """
                SELECT id, kind, title, subtitle, search_text, created_at, last_used_at,
                       is_pinned, byte_count, item_count, type_identifiers, thumbnail, source_bundle_id
                FROM history
                WHERE search_text LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
                ORDER BY is_pinned DESC, last_used_at DESC
                LIMIT ?
                """
        }

        return try withStatement(sql) { statement in
            var limitIndex: Int32 = 1
            if !trimmedQuery.isEmpty {
                let pattern = "%\(escapedLikePattern(trimmedQuery))%"
                try bind(pattern, to: 1, in: statement)
                try bind(pattern, to: 2, in: statement)
                limitIndex = 3
            }
            try bind(limit, to: limitIndex, in: statement)

            var items: [ClipboardHistoryItem] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(code: result) }
                items.append(try decodeHistoryItem(statement))
            }
            return items
        }
    }

    func loadPayload(id: UUID) throws -> ClipboardPayload {
        try ensureInitialized()
        let sourceBundleIdentifier: String? = try withStatement(
            "SELECT source_bundle_id FROM history WHERE id = ?"
        ) { statement in
            try bind(id.uuidString, to: 1, in: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                if result == SQLITE_DONE { throw ClipboardStoreError.itemNotFound(id) }
                throw databaseError(code: result)
            }
            return optionalString(statement, column: 0)
        }

        do {
            return try withStatement(
                """
                SELECT item_index, type_identifier, inline_data, blob_path
            FROM representations
            WHERE history_id = ?
            ORDER BY item_index ASC, representation_index ASC
            """
        ) { statement in
            try bind(id.uuidString, to: 1, in: statement)
            var grouped: [Int: [ClipboardRepresentation]] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(code: result) }
                let itemIndex = Int(sqlite3_column_int(statement, 0))
                let typeIdentifier = requiredString(statement, column: 1)
                let data: Data
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    data = dataValue(statement, column: 2)
                } else if let blobName = optionalString(statement, column: 3) {
                    let url = try validatedBlobURL(fileName: blobName)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw ClipboardStoreError.missingBlob(blobName)
                    }
                    data = try Data(contentsOf: url, options: [.mappedIfSafe])
                } else {
                    throw ClipboardStoreError.corruptRepresentation(id)
                }
                grouped[itemIndex, default: []].append(
                    ClipboardRepresentation(typeIdentifier: typeIdentifier, data: data)
                )
            }
            let items = grouped.keys.sorted().map { ClipboardPayloadItem(representations: grouped[$0] ?? []) }
            guard !items.isEmpty else { throw ClipboardStoreError.corruptRepresentation(id) }
            return ClipboardPayload(items: items, sourceBundleIdentifier: sourceBundleIdentifier)
            }
        } catch let error as ClipboardStoreError {
            switch error {
            case .missingBlob, .invalidBlobPath, .corruptRepresentation:
                try delete(id: id)
                NSLog(
                    "[ClipboardHistoryStore] Removed corrupt item %@ during payload load: %@",
                    id.uuidString,
                    error.localizedDescription
                )
                throw error
            default:
                throw error
            }
        }
    }

    func updateSecurityScopedBookmarks(
        id: UUID,
        bookmarks: [ClipboardRefreshedBookmark]
    ) throws {
        try ensureInitialized()
        guard !bookmarks.isEmpty else { return }
        guard try fetchItem(id: id) != nil else { throw ClipboardStoreError.itemNotFound(id) }
        guard let maximumItemIndex = bookmarks.map(\.itemIndex).max() else { return }

        var payloadItems = Array(
            repeating: ClipboardPayloadItem(representations: []),
            count: maximumItemIndex + 1
        )
        for bookmark in bookmarks {
            payloadItems[bookmark.itemIndex] = ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    typeIdentifier: ClipboardRepresentation.securityScopedBookmarkType,
                    data: bookmark.data
                )
            ])
        }
        try transaction {
            try refreshSecurityScopedBookmarks(
                payload: ClipboardPayload(items: payloadItems),
                historyID: id
            )
        }
    }

    func setPinned(id: UUID, isPinned: Bool) throws {
        try ensureInitialized()
        try updateItem(id: id, sql: "UPDATE history SET is_pinned = ? WHERE id = ?") { statement in
            try bind(isPinned, to: 1, in: statement)
            try bind(id.uuidString, to: 2, in: statement)
        }
    }

    func touch(id: UUID) throws {
        try ensureInitialized()
        try updateItem(id: id, sql: "UPDATE history SET last_used_at = ? WHERE id = ?") { statement in
            try bind(Date().timeIntervalSince1970, to: 1, in: statement)
            try bind(id.uuidString, to: 2, in: statement)
        }
    }

    func delete(id: UUID) throws {
        try ensureInitialized()
        let blobs = try transaction { () -> [String] in
            let names = try blobNames(historyIDs: [id.uuidString])
            try withStatement("DELETE FROM history WHERE id = ?") { statement in
                try bind(id.uuidString, to: 1, in: statement)
                try stepDone(statement)
                guard sqlite3_changes(database) > 0 else { throw ClipboardStoreError.itemNotFound(id) }
            }
            return names
        }
        try removeBlobFiles(named: blobs)
    }

    func clear() throws {
        try ensureInitialized()
        let blobs = try transaction { () -> [String] in
            let names = try allBlobNames()
            try execute("DELETE FROM history")
            return names
        }
        try removeBlobFiles(named: blobs)
    }

    func statistics() throws -> Statistics {
        try ensureInitialized()
        return try withStatement(
            "SELECT COUNT(*), COALESCE(SUM(is_pinned), 0), COALESCE(SUM(byte_count), 0) FROM history"
        ) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw databaseError(code: result) }
            return Statistics(
                itemCount: Int(sqlite3_column_int64(statement, 0)),
                pinnedCount: Int(sqlite3_column_int64(statement, 1)),
                totalBytes: sqlite3_column_int64(statement, 2)
            )
        }
    }

    func configureLimits(maximumItemCount: Int, maximumStorageBytes: Int64) throws {
        guard maximumItemCount > 0 else { throw ClipboardStoreError.invalidItemLimit(maximumItemCount) }
        guard maximumStorageBytes > 0 else { throw ClipboardStoreError.invalidStorageLimit(maximumStorageBytes) }
        try ensureInitialized()
        self.maximumItemCount = maximumItemCount
        self.maximumStorageBytes = maximumStorageBytes
        let prunedBlobNames = try transaction { try pruneIfNeeded() }
        try removeBlobFiles(named: prunedBlobNames)
    }

    private func ensureInitialized() throws {
        guard !isInitialized else { return }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try createSchema()
        try reconcileExternalBlobs()
        isInitialized = true
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY NOT NULL,
                content_hash TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT,
                search_text TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                byte_count INTEGER NOT NULL,
                item_count INTEGER NOT NULL,
                type_identifiers TEXT NOT NULL,
                thumbnail BLOB,
                source_bundle_id TEXT
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS representations (
                history_id TEXT NOT NULL REFERENCES history(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL,
                representation_index INTEGER NOT NULL,
                type_identifier TEXT NOT NULL,
                inline_data BLOB,
                blob_path TEXT,
                byte_count INTEGER NOT NULL,
                PRIMARY KEY (history_id, item_index, representation_index),
                CHECK ((inline_data IS NULL) != (blob_path IS NULL))
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS history_order ON history(is_pinned DESC, last_used_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS representation_history ON representations(history_id)")
    }

    private func fetchItem(id: UUID) throws -> ClipboardHistoryItem? {
        try withStatement(
            """
            SELECT id, kind, title, subtitle, search_text, created_at, last_used_at,
                   is_pinned, byte_count, item_count, type_identifiers, thumbnail, source_bundle_id
            FROM history WHERE id = ?
            """
        ) { statement in
            try bind(id.uuidString, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError(code: result) }
            return try decodeHistoryItem(statement)
        }
    }

    private func decodeHistoryItem(_ statement: OpaquePointer) throws -> ClipboardHistoryItem {
        let idString = requiredString(statement, column: 0)
        let kindString = requiredString(statement, column: 1)
        guard let id = UUID(uuidString: idString), let kind = ClipboardContentKind(rawValue: kindString) else {
            throw ClipboardStoreError.corruptMetadata(idString)
        }
        let typeData = Data(requiredString(statement, column: 10).utf8)
        let typeIdentifiers = try JSONDecoder().decode([String].self, from: typeData)
        return ClipboardHistoryItem(
            id: id,
            kind: kind,
            title: requiredString(statement, column: 2),
            subtitle: optionalString(statement, column: 3),
            searchText: requiredString(statement, column: 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isPinned: sqlite3_column_int(statement, 7) != 0,
            byteCount: sqlite3_column_int64(statement, 8),
            itemCount: Int(sqlite3_column_int64(statement, 9)),
            typeIdentifiers: typeIdentifiers,
            thumbnailData: sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : dataValue(statement, column: 11),
            sourceBundleIdentifier: optionalString(statement, column: 12)
        )
    }

    private func identifier(forContentHash hash: String) throws -> UUID? {
        try withStatement("SELECT id FROM history WHERE content_hash = ?") { statement in
            try bind(hash, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError(code: result) }
            return UUID(uuidString: requiredString(statement, column: 0))
        }
    }

    private func refreshSecurityScopedBookmarks(
        payload: ClipboardPayload,
        historyID: UUID
    ) throws {
        var updatedBookmark = false
        for (itemIndex, payloadItem) in payload.items.enumerated() {
            guard let bookmark = payloadItem.representations.first(where: {
                $0.typeIdentifier == ClipboardRepresentation.securityScopedBookmarkType
            }) else { continue }

            let existingIndex: Int? = try withStatement(
                """
                SELECT representation_index FROM representations
                WHERE history_id = ? AND item_index = ? AND type_identifier = ?
                LIMIT 1
                """
            ) { statement in
                try bind(historyID.uuidString, to: 1, in: statement)
                try bind(itemIndex, to: 2, in: statement)
                try bind(ClipboardRepresentation.securityScopedBookmarkType, to: 3, in: statement)
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw databaseError(code: result) }
                return Int(sqlite3_column_int64(statement, 0))
            }

            if let existingIndex {
                try withStatement(
                    """
                    UPDATE representations
                    SET inline_data = ?, blob_path = NULL, byte_count = ?
                    WHERE history_id = ? AND item_index = ? AND representation_index = ?
                    """
                ) { statement in
                    try bind(bookmark.data, to: 1, in: statement)
                    try bind(bookmark.data.count, to: 2, in: statement)
                    try bind(historyID.uuidString, to: 3, in: statement)
                    try bind(itemIndex, to: 4, in: statement)
                    try bind(existingIndex, to: 5, in: statement)
                    try stepDone(statement)
                }
            } else {
                let nextIndex: Int = try withStatement(
                    """
                    SELECT COALESCE(MAX(representation_index), -1) + 1
                    FROM representations WHERE history_id = ? AND item_index = ?
                    """
                ) { statement in
                    try bind(historyID.uuidString, to: 1, in: statement)
                    try bind(itemIndex, to: 2, in: statement)
                    let result = sqlite3_step(statement)
                    guard result == SQLITE_ROW else { throw databaseError(code: result) }
                    return Int(sqlite3_column_int64(statement, 0))
                }
                try withStatement(
                    """
                    INSERT INTO representations (
                        history_id, item_index, representation_index, type_identifier,
                        inline_data, blob_path, byte_count
                    ) VALUES (?, ?, ?, ?, ?, NULL, ?)
                    """
                ) { statement in
                    try bind(historyID.uuidString, to: 1, in: statement)
                    try bind(itemIndex, to: 2, in: statement)
                    try bind(nextIndex, to: 3, in: statement)
                    try bind(ClipboardRepresentation.securityScopedBookmarkType, to: 4, in: statement)
                    try bind(bookmark.data, to: 5, in: statement)
                    try bind(bookmark.data.count, to: 6, in: statement)
                    try stepDone(statement)
                }
            }
            updatedBookmark = true
        }

        if updatedBookmark {
            try withStatement(
                """
                UPDATE history
                SET byte_count = (
                    SELECT COALESCE(SUM(byte_count), 0)
                    FROM representations WHERE history_id = ?
                )
                WHERE id = ?
                """
            ) { statement in
                try bind(historyID.uuidString, to: 1, in: statement)
                try bind(historyID.uuidString, to: 2, in: statement)
                try stepDone(statement)
            }
        }
    }

    private func updateItem(
        id: UUID,
        sql: String,
        bindings: (OpaquePointer) throws -> Void
    ) throws {
        try transaction {
            try withStatement(sql) { statement in
                try bindings(statement)
                try stepDone(statement)
                guard sqlite3_changes(database) > 0 else { throw ClipboardStoreError.itemNotFound(id) }
            }
        }
    }

    private func pruneIfNeeded() throws -> [String] {
        let statistics = try statistics()
        guard statistics.itemCount > maximumItemCount || statistics.totalBytes > maximumStorageBytes else {
            return []
        }

        let candidates: [(String, Int64)] = try withStatement(
            "SELECT id, byte_count FROM history WHERE is_pinned = 0 ORDER BY last_used_at ASC"
        ) { statement in
            var values: [(String, Int64)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(code: result) }
                values.append((requiredString(statement, column: 0), sqlite3_column_int64(statement, 1)))
            }
            return values
        }

        var currentCount = statistics.itemCount
        var currentBytes = statistics.totalBytes
        var identifiersToDelete: [String] = []
        for candidate in candidates {
            guard currentCount > maximumItemCount || currentBytes > maximumStorageBytes else { break }
            identifiersToDelete.append(candidate.0)
            currentCount -= 1
            currentBytes -= candidate.1
        }
        guard !identifiersToDelete.isEmpty else { return [] }
        let blobNames = try blobNames(historyIDs: identifiersToDelete)
        for identifier in identifiersToDelete {
            try withStatement("DELETE FROM history WHERE id = ?") { statement in
                try bind(identifier, to: 1, in: statement)
                try stepDone(statement)
            }
        }
        return blobNames
    }

    private func contentHash(for payload: ClipboardPayload) -> String {
        var hasher = SHA256()
        append(UInt64(payload.items.count), to: &hasher)
        for item in payload.items {
            let sortedRepresentations = item.representations
                .filter { $0.typeIdentifier != ClipboardRepresentation.securityScopedBookmarkType }
                .sorted { lhs, rhs in
                lhs.typeIdentifier == rhs.typeIdentifier
                    ? lhs.data.lexicographicallyPrecedes(rhs.data)
                    : lhs.typeIdentifier < rhs.typeIdentifier
            }
            append(UInt64(sortedRepresentations.count), to: &hasher)
            for representation in sortedRepresentations {
                let typeData = Data(representation.typeIdentifier.utf8)
                append(UInt64(typeData.count), to: &hasher)
                hasher.update(data: typeData)
                append(UInt64(representation.data.count), to: &hasher)
                hasher.update(data: representation.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func append(_ value: UInt64, to hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
    }

    private func reconcileExternalBlobs() throws {
        let externalReferences: [(historyID: String, fileName: String)] = try withStatement(
            "SELECT history_id, blob_path FROM representations WHERE blob_path IS NOT NULL"
        ) { statement in
            var references: [(String, String)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(code: result) }
                references.append((
                    requiredString(statement, column: 0),
                    requiredString(statement, column: 1)
                ))
            }
            return references
        }

        var corruptHistoryIDs = Set<String>()
        var missingNames: [String] = []
        for reference in externalReferences {
            do {
                let url = try validatedBlobURL(fileName: reference.fileName)
                if !FileManager.default.fileExists(atPath: url.path) {
                    corruptHistoryIDs.insert(reference.historyID)
                    missingNames.append(reference.fileName)
                }
            } catch {
                corruptHistoryIDs.insert(reference.historyID)
                missingNames.append("invalid:\(reference.fileName)")
                NSLog(
                    "[ClipboardHistoryStore] Invalid blob reference for item %@: %@",
                    reference.historyID,
                    error.localizedDescription
                )
            }
        }

        if !corruptHistoryIDs.isEmpty {
            try transaction {
                for historyID in corruptHistoryIDs {
                    try withStatement("DELETE FROM history WHERE id = ?") { statement in
                        try bind(historyID, to: 1, in: statement)
                        try stepDone(statement)
                    }
                }
            }
            NSLog(
                "[ClipboardHistoryStore] Removed %d corrupt item(s) with missing blobs: %@",
                corruptHistoryIDs.count,
                missingNames.joined(separator: ", ")
            )
        }

        let referenced = Set(try allBlobNames())
        let contents = try FileManager.default.contentsOfDirectory(
            at: blobsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents where !referenced.contains(url.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog(
                    "[ClipboardHistoryStore] Deferred orphan blob cleanup for %@: %@",
                    url.lastPathComponent,
                    error.localizedDescription
                )
            }
        }
    }

    private func allBlobNames() throws -> [String] {
        try withStatement("SELECT blob_path FROM representations WHERE blob_path IS NOT NULL") { statement in
            var names: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(code: result) }
                if let name = optionalString(statement, column: 0) { names.append(name) }
            }
            return names
        }
    }

    private func blobNames(historyIDs: [String]) throws -> [String] {
        guard !historyIDs.isEmpty else { return [] }
        var names: [String] = []
        for identifier in historyIDs {
            let values: [String] = try withStatement(
                "SELECT blob_path FROM representations WHERE history_id = ? AND blob_path IS NOT NULL"
            ) { statement in
                try bind(identifier, to: 1, in: statement)
                var resultNames: [String] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw databaseError(code: result) }
                    if let name = optionalString(statement, column: 0) { resultNames.append(name) }
                }
                return resultNames
            }
            names.append(contentsOf: values)
        }
        return names
    }

    private func removeBlobFiles(named names: [String]) throws {
        var failures: [String] = []
        for name in Set(names) {
            do {
                let url = try validatedBlobURL(fileName: name)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            NSLog(
                "[ClipboardHistoryStore] Deferred cleanup for %d blob(s): %@",
                failures.count,
                failures.joined(separator: "; ")
            )
        }
    }

    private func validatedBlobURL(fileName: String) throws -> URL {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent, !fileName.isEmpty else {
            throw ClipboardStoreError.invalidBlobPath(fileName)
        }
        return blobsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func escapedLikePattern(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw ClipboardStoreError.databaseClosed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw ClipboardStoreError.sqlite(code: result, message: message)
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw ClipboardStoreError.databaseClosed }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw databaseError(code: result) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw databaseError(code: result) }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Data?, to index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            if value.isEmpty {
                result = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
                }
            }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Int, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Bool, to index: Int32, in statement: OpaquePointer) throws {
        try bind(value ? 1 : 0, to: index, in: statement)
    }

    private func requiredString(_ statement: OpaquePointer, column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }

    private func optionalString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private func dataValue(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func databaseError(code: Int32) -> ClipboardStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed"
        return .sqlite(code: code, message: message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardStoreError: LocalizedError {
    case invalidItemLimit(Int)
    case invalidStorageLimit(Int64)
    case openFailed(String)
    case databaseClosed
    case sqlite(code: Int32, message: String)
    case emptyPayload
    case itemExceedsStorageLimit(itemBytes: Int64, limitBytes: Int64)
    case itemNotFound(UUID)
    case corruptMetadata(String)
    case corruptRepresentation(UUID)
    case missingBlob(String)
    case invalidBlobPath(String)
    case blobCleanupFailed([String])

    var errorDescription: String? {
        switch self {
        case .invalidItemLimit(let value): return "Clipboard item limit must be positive; received \(value)."
        case .invalidStorageLimit(let value): return "Clipboard storage limit must be positive; received \(value)."
        case .openFailed(let message): return "Unable to open clipboard database: \(message)"
        case .databaseClosed: return "Clipboard database is closed."
        case .sqlite(let code, let message): return "Clipboard database error \(code): \(message)"
        case .emptyPayload: return "Cannot store an empty clipboard payload."
        case .itemExceedsStorageLimit(let itemBytes, let limitBytes):
            return "Clipboard item is \(itemBytes) bytes, exceeding the \(limitBytes)-byte storage limit."
        case .itemNotFound(let id): return "Clipboard item \(id.uuidString) was not found."
        case .corruptMetadata(let id): return "Clipboard metadata is corrupt for item \(id)."
        case .corruptRepresentation(let id): return "Clipboard data is corrupt for item \(id.uuidString)."
        case .missingBlob(let name): return "Clipboard blob \(name) is missing from disk."
        case .invalidBlobPath(let path): return "Clipboard blob path is invalid: \(path)."
        case .blobCleanupFailed(let failures): return "Unable to clean clipboard blobs: \(failures.joined(separator: "; "))"
        }
    }
}
