import AppKit
import SwiftUI

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryViewModel

    init(model: ClipboardHistoryViewModel) {
        self.model = model
    }

    init() {
        self.model = ClipboardHistoryViewModel.shared
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button("Clear") { model.clear() }
                    .buttonStyle(.plain)
                    .disabled(model.items.isEmpty)
            }
            .padding(9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if model.filteredItems.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "Clipboard is empty" : "No matches",
                    systemImage: "clipboard",
                    description: Text(model.searchText.isEmpty ? "Copied text, images, and files appear here." : "Try another search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.filteredItems) { item in
                            ClipboardHistoryRow(item: item) {
                                model.copy(item)
                            } onDelete: {
                                model.delete(item)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                preview
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .lineLimit(2)
                        .font(.system(size: 13, weight: .medium))
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .lineLimit(1)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .contentShape(Rectangle())
            .padding(8)
            .background(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: onSelect)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo")
            }
        case .files(let urls):
            if let url = urls.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
            }
        }
    }
}
