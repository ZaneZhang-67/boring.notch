import AppKit
import SwiftUI

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryViewModel
    @FocusState private var searchIsFocused: Bool
    @State private var selectedID: UUID?
    @State private var confirmClear = false

    init(model: ClipboardHistoryViewModel) {
        self.model = model
    }

    init() {
        self.model = ClipboardHistoryViewModel.shared
    }

    var body: some View {
        VStack(spacing: 6) {
            searchBar

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }

            if model.items.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onAppear {
            selectFirstItemIfNeeded()
            DispatchQueue.main.async { searchIsFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardPanelDidOpen)) { _ in
            selectedID = nil
            model.searchText = ""
            DispatchQueue.main.async { searchIsFocused = true }
        }
        .onChange(of: model.items) { _, _ in
            selectFirstItemIfNeeded()
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onExitCommand {
            NotificationCenter.default.post(name: .clipboardPanelShouldClose, object: nil)
        }
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes pinned and unpinned entries.")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search \(model.statistics.itemCount) clipboard items", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .onSubmit { copySelectedItem() }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
            Text(ByteCountFormatter.string(fromByteCount: model.statistics.totalBytes, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(model.statistics.itemCount == 0)
            .help("Clear history")
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: model.searchText.isEmpty ? "clipboard" : "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(model.searchText.isEmpty ? "Clipboard history is empty" : "No matches")
                .font(.caption)
            if model.searchText.isEmpty {
                Text("Text, rich content, images, and files you copy will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.items) { item in
                        ClipboardHistoryRow(
                            item: item,
                            isSelected: selectedID == item.id,
                            onSelect: {
                                selectedID = item.id
                                copy(item)
                            },
                            onPin: { model.togglePinned(item) },
                            onDelete: { model.delete(item) }
                        )
                        .id(item.id)
                    }
                }
            }
            .onChange(of: selectedID) { _, id in
                if let id {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func selectFirstItemIfNeeded() {
        if let selectedID, model.items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = model.items.first?.id
    }

    private func moveSelection(by offset: Int) {
        guard !model.items.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in model.items.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), model.items.count - 1)
        selectedID = model.items[nextIndex].id
    }

    private func copySelectedItem() {
        guard let selectedID,
              let item = model.items.first(where: { $0.id == selectedID }) else { return }
        copy(item)
    }

    private func copy(_ item: ClipboardHistoryItem) {
        model.copy(item) {
            NotificationCenter.default.post(name: .clipboardSelectionCompleted, object: nil)
        }
    }

}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    preview
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.yellow)
                            }
                            Text(item.title.isEmpty ? "Clipboard data" : item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Text(item.kind.label)
                            if item.itemCount > 1 {
                                Text("\(item.itemCount) items")
                            }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering || isSelected {
                Button(action: onPin) {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 39)
        .background(
            isSelected ? Color.accentColor.opacity(0.28) : (hovering ? Color.white.opacity(0.09) : Color.white.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: onSelect)
            Button(item.isPinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let data = item.thumbnailData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: item.kind.icon)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
    }
}

private extension ClipboardContentKind {
    var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich text"
        case .html: "HTML"
        case .image: "Image"
        case .files: "Files"
        case .folder: "Folder"
        case .url: "Link"
        case .other: "Data"
        }
    }

    var icon: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .files: "doc.on.doc"
        case .folder: "folder.fill"
        case .url: "link"
        case .other: "shippingbox"
        }
    }
}

extension Notification.Name {
    static let clipboardPanelOpenRequested = Notification.Name("ClipboardPanelOpenRequested")
    static let clipboardPanelSwitchRequested = Notification.Name("ClipboardPanelSwitchRequested")
    static let clipboardPanelDidOpen = Notification.Name("ClipboardPanelDidOpen")
    static let clipboardSelectionCompleted = Notification.Name("ClipboardSelectionCompleted")
    static let clipboardPanelShouldClose = Notification.Name("ClipboardPanelShouldClose")
}
