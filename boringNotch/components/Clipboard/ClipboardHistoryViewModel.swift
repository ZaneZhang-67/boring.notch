import AppKit
import Defaults
import Foundation

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    static let shared = ClipboardHistoryViewModel()

    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var statistics = ClipboardHistoryStore.Statistics(
        itemCount: 0,
        pinnedCount: 0,
        totalBytes: 0
    )
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastIgnoredReason: ClipboardCaptureIgnoreReason?
    @Published var errorMessage: String?
    @Published var searchText = "" {
        didSet { scheduleReload() }
    }

    private let pasteboard: NSPasteboard
    private let legacyPersistenceURL: URL
    private var store: ClipboardHistoryStore?
    private var lastChangeCount: Int
    private var timer: Timer?
    private var isWritingPasteboard = false
    private var ingestionTask: Task<Void, Never>?
    private var ingestionWorkerID: UUID?
    private var pendingCaptures: [CapturedClipboard] = []
    private var searchTask: Task<Void, Never>?
    private var migrationTask: Task<Void, Never>?
    private var copyingItemID: UUID?
    private var hasMigratedLegacyHistory = false

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("boringNotch", isDirectory: true)
        self.legacyPersistenceURL = directory.appendingPathComponent("ClipboardHistory.json")

        do {
            store = try ClipboardHistoryStore(
                baseDirectory: directory,
                maximumItemCount: max(1, Defaults[.clipboardMaximumItems]),
                maximumStorageBytes: Int64(max(1, Defaults[.clipboardMaximumStorageMB])) * 1024 * 1024
            )
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[ClipboardHistory] Storage initialization failed: %@", error.localizedDescription)
        }

        migrationTask = Task { [weak self] in
            guard let self else { return }
            await self.migrateLegacyHistoryIfNeeded()
            guard !Task.isCancelled else { return }
            await self.reload()
        }
    }

    deinit {
        timer?.invalidate()
        ingestionTask?.cancel()
        searchTask?.cancel()
        migrationTask?.cancel()
    }

    func startMonitoring() {
        guard Defaults[.clipboardHistoryEnabled], timer == nil, store != nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isMonitoring = true
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        ingestionTask?.cancel()
        ingestionTask = nil
        ingestionWorkerID = nil
        pendingCaptures.removeAll()
        isMonitoring = false
    }

    func applyPreferences() {
        if Defaults[.clipboardHistoryEnabled] {
            startMonitoring()
        } else {
            stopMonitoring()
        }

        guard let store else { return }
        Task { [weak self] in
            do {
                try await store.configureLimits(
                    maximumItemCount: max(1, Defaults[.clipboardMaximumItems]),
                    maximumStorageBytes: Int64(max(1, Defaults[.clipboardMaximumStorageMB])) * 1024 * 1024
                )
                await self?.reload()
            } catch {
                self?.report(error)
            }
        }
    }

    func captureCurrentClipboard() {
        lastChangeCount = pasteboard.changeCount
        captureAndEnqueue()
    }

    func copy(_ item: ClipboardHistoryItem, completion: (() -> Void)? = nil) {
        guard let store else {
            report(ClipboardHistoryError.storageUnavailable)
            return
        }
        guard copyingItemID == nil else { return }
        copyingItemID = item.id

        Task { [weak self] in
            guard let self else { return }
            defer { self.copyingItemID = nil }
            do {
                let payload = try await store.loadPayload(id: item.id)
                self.isWritingPasteboard = true
                let writeResult: ClipboardWriteResult
                do {
                    writeResult = try ClipboardCapture.write(payload, to: self.pasteboard)
                } catch {
                    self.lastChangeCount = self.pasteboard.changeCount
                    self.isWritingPasteboard = false
                    throw error
                }
                self.lastChangeCount = self.pasteboard.changeCount
                self.isWritingPasteboard = false
                NSLog(
                    "[ClipboardHistory] restored id=%@ items=%d representations=%d bytes=%lld",
                    item.id.uuidString,
                    payload.items.count,
                    payload.items.reduce(0) { $0 + $1.representations.count },
                    payload.byteCount
                )
                // Clipboard restoration is the user-visible success boundary. Close the panel
                // immediately; metadata bookkeeping must not make a successful copy feel stuck.
                completion?()
                if !writeResult.refreshedBookmarks.isEmpty {
                    try await store.updateSecurityScopedBookmarks(
                        id: item.id,
                        bookmarks: writeResult.refreshedBookmarks
                    )
                }
                try await store.touch(id: item.id)
                await self.reload()
            } catch {
                await self.reload()
                self.report(error)
            }
        }
    }

    func togglePinned(_ item: ClipboardHistoryItem) {
        guard let store else {
            report(ClipboardHistoryError.storageUnavailable)
            return
        }
        Task { [weak self] in
            do {
                try await store.setPinned(id: item.id, isPinned: !item.isPinned)
                await self?.reload()
            } catch {
                self?.report(error)
            }
        }
    }

    func delete(_ item: ClipboardHistoryItem) {
        guard let store else {
            report(ClipboardHistoryError.storageUnavailable)
            return
        }
        Task { [weak self] in
            do {
                try await store.delete(id: item.id)
                await self?.reload()
            } catch {
                self?.report(error)
            }
        }
    }

    func clear() {
        guard let store else {
            report(ClipboardHistoryError.storageUnavailable)
            return
        }
        ingestionTask?.cancel()
        ingestionTask = nil
        ingestionWorkerID = nil
        pendingCaptures.removeAll()
        migrationTask?.cancel()
        migrationTask = nil
        Task { [weak self] in
            do {
                try await store.clear()
                await self?.reload()
            } catch {
                self?.report(error)
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func pollPasteboard() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        guard !isWritingPasteboard else { return }
        ClipboardCapture.releaseSecurityScopedResources()
        captureAndEnqueue()
    }

    private func captureAndEnqueue() {
        guard let store else { return }
        do {
            switch try ClipboardCapture.read(from: pasteboard) {
            case .ignored(let reason):
                lastIgnoredReason = reason
                NSLog("[ClipboardHistory] Ignored clipboard update: %@", reason.rawValue)
            case .captured(let capture):
                guard shouldStore(kind: capture.kind) else {
                    lastIgnoredReason = .unsupported
                    return
                }
                lastIgnoredReason = nil
                pendingCaptures.append(capture)
                startIngestionWorkerIfNeeded(store: store)
            }
        } catch {
            report(error)
        }
    }

    private func startIngestionWorkerIfNeeded(store: ClipboardHistoryStore) {
        guard ingestionTask == nil else { return }
        let workerID = UUID()
        ingestionWorkerID = workerID
        ingestionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ingestionWorkerID == workerID {
                    self.ingestionTask = nil
                    self.ingestionWorkerID = nil
                }
            }

            while !Task.isCancelled, Defaults[.clipboardHistoryEnabled] {
                guard !self.pendingCaptures.isEmpty else { return }
                let capture = self.pendingCaptures.removeFirst()
                do {
                    let storedItem = try await store.upsert(
                        payload: capture.payload,
                        kind: capture.kind,
                        title: capture.title,
                        subtitle: capture.subtitle,
                        searchText: capture.searchText,
                        thumbnailData: capture.thumbnailData
                    )
                    guard !Task.isCancelled, Defaults[.clipboardHistoryEnabled] else { return }
                    NSLog(
                        "[ClipboardHistory] stored id=%@ kind=%@ items=%d representations=%d bytes=%lld",
                        storedItem.id.uuidString,
                        storedItem.kind.rawValue,
                        capture.payload.items.count,
                        capture.payload.items.reduce(0) { $0 + $1.representations.count },
                        capture.payload.byteCount
                    )
                    await self.reload()
                } catch is CancellationError {
                    return
                } catch {
                    self.report(error)
                }
            }
        }
    }

    private func scheduleReload() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            await self?.reload()
        }
    }

    private func reload() async {
        guard let store else { return }
        do {
            let query = searchText
            async let fetchedItems = store.fetch(
                query: query,
                limit: max(1, Defaults[.clipboardMaximumItems])
            )
            async let fetchedStatistics = store.statistics()
            let (newItems, newStatistics) = try await (fetchedItems, fetchedStatistics)
            guard query == searchText else { return }
            items = newItems
            statistics = newStatistics
        } catch {
            report(error)
        }
    }

    private func migrateLegacyHistoryIfNeeded() async {
        guard !hasMigratedLegacyHistory, let store else { return }
        hasMigratedLegacyHistory = true
        guard FileManager.default.fileExists(atPath: legacyPersistenceURL.path) else { return }

        do {
            let data = try Data(contentsOf: legacyPersistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let legacyItems = try decoder.decode([ClipboardItem].self, from: data)

            for item in legacyItems.reversed() {
                try Task.checkCancellation()
                let migration = legacyCapture(for: item)
                _ = try await store.upsert(
                    payload: migration.payload,
                    kind: migration.kind,
                    title: migration.title,
                    subtitle: migration.subtitle,
                    searchText: migration.searchText,
                    thumbnailData: migration.thumbnailData
                )
            }

            let migratedURL = legacyPersistenceURL.appendingPathExtension("migrated")
            if FileManager.default.fileExists(atPath: migratedURL.path) {
                try FileManager.default.removeItem(at: migratedURL)
            }
            try FileManager.default.moveItem(at: legacyPersistenceURL, to: migratedURL)
            NSLog("[ClipboardHistory] Migrated %d legacy items to SQLite", legacyItems.count)
        } catch is CancellationError {
            return
        } catch {
            report(ClipboardHistoryError.legacyMigrationFailed(error.localizedDescription))
        }
    }

    private func legacyCapture(for item: ClipboardItem) -> CapturedClipboard {
        switch item.content {
        case .text(let text):
            return CapturedClipboard(
                payload: ClipboardPayload(items: [
                    ClipboardPayloadItem(representations: [
                        ClipboardRepresentation(
                            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                            data: Data(text.utf8)
                        )
                    ])
                ]),
                kind: .text,
                title: item.title,
                subtitle: item.detail,
                searchText: item.searchText,
                thumbnailData: nil
            )
        case .image(let data):
            return CapturedClipboard(
                payload: ClipboardPayload(items: [
                    ClipboardPayloadItem(representations: [
                        ClipboardRepresentation(
                            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue,
                            data: data
                        )
                    ])
                ]),
                kind: .image,
                title: item.title,
                subtitle: item.detail,
                searchText: item.searchText,
                thumbnailData: nil
            )
        case .files(let urls):
            let payloadItems = urls.map { url in
                var representations = [
                    ClipboardRepresentation(
                        typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue,
                        data: Data(url.absoluteString.utf8)
                    )
                ]
                if let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    representations.append(
                        ClipboardRepresentation(
                            typeIdentifier: ClipboardRepresentation.securityScopedBookmarkType,
                            data: bookmark
                        )
                    )
                }
                return ClipboardPayloadItem(representations: representations)
            }
            return CapturedClipboard(
                payload: ClipboardPayload(items: payloadItems),
                kind: .files,
                title: item.title,
                subtitle: item.detail,
                searchText: item.searchText,
                thumbnailData: nil
            )
        }
    }

    private func shouldStore(kind: ClipboardContentKind) -> Bool {
        switch kind {
        case .image:
            Defaults[.clipboardCaptureImages]
        case .files, .folder:
            Defaults[.clipboardCaptureFiles]
        case .html, .richText:
            Defaults[.clipboardCaptureRichText]
        case .text, .url, .other:
            true
        }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        NSLog("[ClipboardHistory] %@", error.localizedDescription)
    }
}

enum ClipboardHistoryError: LocalizedError {
    case storageUnavailable
    case legacyMigrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Clipboard history storage is unavailable."
        case .legacyMigrationFailed(let reason):
            return "Unable to migrate the previous clipboard history: \(reason)"
        }
    }
}
