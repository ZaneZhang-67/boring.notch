import AppKit
import Foundation

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    static let shared = ClipboardHistoryViewModel()

    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchText = ""

    var filteredItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }

    private let pasteboard: NSPasteboard
    private let maximumItemCount: Int
    private let persistenceURL: URL
    private var lastChangeCount: Int
    private var timer: Timer?
    private var isWritingPasteboard = false

    init(pasteboard: NSPasteboard = .general, maximumItemCount: Int = 100) {
        self.pasteboard = pasteboard
        self.maximumItemCount = maximumItemCount
        self.lastChangeCount = pasteboard.changeCount
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("boringNotch", isDirectory: true)
        self.persistenceURL = directory.appendingPathComponent("ClipboardHistory.json")
        self.items = Self.load(from: persistenceURL)
        startMonitoring()
    }

    deinit { timer?.invalidate() }

    func startMonitoring() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func copy(_ item: ClipboardItem) {
        isWritingPasteboard = true
        defer {
            lastChangeCount = pasteboard.changeCount
            isWritingPasteboard = false
        }
        pasteboard.clearContents()
        switch item.content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let data):
            pasteboard.setData(data, forType: .png)
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
        moveToFront(item)
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func pollPasteboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isWritingPasteboard, let item = readCurrentItem() else { return }
        insert(item)
    }

    private func readCurrentItem() -> ClipboardItem? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
           let urls = objects.compactMap({ $0 as? URL }).nilIfEmpty {
            return ClipboardItem(content: .files(urls))
        }
        if let data = pasteboard.data(forType: .png), NSImage(data: data) != nil {
            return ClipboardItem(content: .image(data))
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return ClipboardItem(content: .image(png))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return ClipboardItem(content: .text(text))
        }
        return nil
    }

    private func insert(_ item: ClipboardItem) {
        items.removeAll { $0.deduplicationKey == item.deduplicationKey }
        items.insert(item, at: 0)
        if items.count > maximumItemCount { items.removeLast(items.count - maximumItemCount) }
        persist()
    }

    private func moveToFront(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let existing = items.remove(at: index)
        items.insert(existing, at: 0)
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(items).write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("Unable to persist clipboard history: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClipboardItem].self, from: data)) ?? []
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
