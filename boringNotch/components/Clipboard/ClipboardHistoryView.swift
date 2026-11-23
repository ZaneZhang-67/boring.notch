import AppKit
import SwiftUI

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryViewModel
    @ObservedObject var viewModel: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchIsFocused: Bool
    @Namespace private var previewTransitionNamespace
    @State private var selectedID: UUID?
    @State private var listScrollPositionID: UUID?
    @State private var previewReturnPositionID: UUID?
    @State private var previewItemID: UUID?
    @State private var previewImage: NSImage?
    @State private var confirmClear = false

    init(viewModel: BoringViewModel) {
        self.model = .shared
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            if let previewedItem {
                expandedImagePreview(for: previewedItem)
                    .transition(previewTransition(scale: 0.96))
            } else {
                normalContent
                    .transition(previewTransition(scale: 0.985))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
        .background(
            ClipboardArrowKeyMonitor(
                isEnabled: viewModel.clipboardOwnsKeyboardFocus,
                isPreviewExpanded: previewItemID != nil,
                onUpArrow: { moveSelectionIfPossible(by: -1) },
                onDownArrow: { moveSelectionIfPossible(by: 1) },
                onRightArrow: { expandSelectedImage() },
                onLeftArrow: {
                    guard previewItemID != nil else { return false }
                    collapseImagePreview()
                    return true
                }
            )
        )
        .onAppear {
            selectFirstItemIfNeeded()
            guard viewModel.clipboardOwnsKeyboardFocus else { return }
            DispatchQueue.main.async { searchIsFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardPanelDidOpen)) { notification in
            guard let openedViewModel = notification.object as? BoringViewModel,
                  openedViewModel === viewModel else { return }
            selectedID = nil
            listScrollPositionID = nil
            previewReturnPositionID = nil
            previewItemID = nil
            previewImage = nil
            model.searchText = ""
            selectFirstItemIfNeeded()
            DispatchQueue.main.async { searchIsFocused = true }
        }
        .onChange(of: model.items) { _, items in
            selectFirstItemIfNeeded()
            let fallbackID = selectedID.flatMap { selectedID in
                items.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? items.first?.id
            if let listScrollPositionID,
               !items.contains(where: { $0.id == listScrollPositionID }) {
                self.listScrollPositionID = fallbackID
            }
            if let previewReturnPositionID,
               !items.contains(where: { $0.id == previewReturnPositionID }) {
                self.previewReturnPositionID = fallbackID
            }
            if let previewItemID, !items.contains(where: { $0.id == previewItemID }) {
                collapseImagePreview()
            }
        }
        .onExitCommand {
            NotificationCenter.default.post(name: .clipboardPanelShouldClose, object: nil)
        }
        .task(id: previewItemID) {
            guard let previewItemID,
                  let item = model.items.first(where: { $0.id == previewItemID }) else { return }
            let originalImage = await model.loadPreviewImage(for: item)
            guard !Task.isCancelled, self.previewItemID == previewItemID else { return }
            if let originalImage {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    previewImage = originalImage
                }
            } else if previewImage == nil {
                collapseImagePreview()
            }
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

    private var normalContent: some View {
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
    }

    private var previewedItem: ClipboardHistoryItem? {
        guard let previewItemID else { return nil }
        return model.items.first(where: { $0.id == previewItemID })
    }

    private func expandedImagePreview(for item: ClipboardHistoryItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.72))

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .matchedGeometryEffect(
                        id: item.id,
                        in: previewTransitionNamespace,
                        isSource: false
                    )
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            VStack {
                HStack(spacing: 8) {
                    Text(item.title.isEmpty ? "Image" : item.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Label("Left arrow to shrink", systemImage: "arrow.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Expanded clipboard image")
        .accessibilityHint("Press the left arrow key to return to the clipboard list")
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search \(model.statistics.itemCount) clipboard items", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .onSubmit { copySelectedItem() }
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
            .disabled(model.statistics.itemCount == 0 && !model.isClearing)
            .help(model.isClearing ? "Retry clearing history" : "Clear history")
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
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(model.items) { item in
                    ClipboardHistoryRow(
                        item: item,
                        isSelected: selectedID == item.id,
                        previewNamespace: previewTransitionNamespace,
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
            .scrollTargetLayout()
        }
        .scrollPosition(id: $listScrollPositionID, anchor: .center)
        .onChange(of: selectedID) { _, id in
            guard let id else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                listScrollPositionID = id
            }
        }
    }

    private func previewTransition(scale: CGFloat) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: scale))
    }

    private var previewTransitionAnimation: Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.12)
    }

    @discardableResult
    private func expandSelectedImage() -> Bool {
        guard previewItemID == nil,
              let imageID = selectedID,
              let item = model.items.first(where: {
                  $0.id == imageID && $0.kind == .image
              }) else { return false }

        previewReturnPositionID = listScrollPositionID ?? selectedID
        previewImage = item.thumbnailData.flatMap(NSImage.init(data:))
        searchIsFocused = false
        withAnimation(previewTransitionAnimation) {
            previewItemID = item.id
        }
        NSLog("[ClipboardPreview] expanded id=%@", item.id.uuidString)
        return true
    }

    private func collapseImagePreview() {
        if let previewItemID {
            NSLog("[ClipboardPreview] collapsed id=%@", previewItemID.uuidString)
        }
        let returnPositionID = previewReturnPositionID
        previewReturnPositionID = nil
        if let returnPositionID {
            listScrollPositionID = returnPositionID
        }
        withAnimation(previewTransitionAnimation) {
            previewItemID = nil
            previewImage = nil
        }
        DispatchQueue.main.async { searchIsFocused = true }
    }

    private func selectFirstItemIfNeeded() {
        if let selectedID, model.items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = model.items.first?.id
    }

    private func moveSelectionIfPossible(by offset: Int) -> Bool {
        guard previewItemID == nil, !model.items.isEmpty else { return false }
        let currentIndex = selectedID.flatMap { id in model.items.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), model.items.count - 1)
        selectedID = model.items[nextIndex].id
        return true
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

private struct ClipboardArrowKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let isPreviewExpanded: Bool
    let onUpArrow: () -> Bool
    let onDownArrow: () -> Bool
    let onRightArrow: () -> Bool
    let onLeftArrow: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onRightArrow: onRightArrow,
            onLeftArrow: onLeftArrow
        )
    }

    func makeNSView(context: Context) -> KeySinkView {
        let view = KeySinkView(frame: .zero)
        context.coordinator.keySinkView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: KeySinkView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isEnabled = isEnabled
        coordinator.isPreviewExpanded = isPreviewExpanded
        coordinator.onUpArrow = onUpArrow
        coordinator.onDownArrow = onDownArrow
        coordinator.onRightArrow = onRightArrow
        coordinator.onLeftArrow = onLeftArrow
        guard isEnabled,
              isPreviewExpanded,
              nsView.window?.isKeyWindow == true,
              nsView.window?.firstResponder !== nsView else { return }
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
            guard let nsView,
                  let coordinator,
                  coordinator.isEnabled,
                  coordinator.isPreviewExpanded,
                  nsView.window?.isKeyWindow == true else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    static func dismantleNSView(_ nsView: KeySinkView, coordinator: Coordinator) {
        coordinator.keySinkView = nil
        coordinator.uninstall()
    }

    final class KeySinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class Coordinator {
        weak var keySinkView: KeySinkView?
        var isEnabled = false
        var isPreviewExpanded = false
        var onUpArrow: () -> Bool
        var onDownArrow: () -> Bool
        var onRightArrow: () -> Bool
        var onLeftArrow: () -> Bool
        private var monitor: Any?

        init(
            onUpArrow: @escaping () -> Bool,
            onDownArrow: @escaping () -> Bool,
            onRightArrow: @escaping () -> Bool,
            onLeftArrow: @escaping () -> Bool
        ) {
            self.onUpArrow = onUpArrow
            self.onDownArrow = onDownArrow
            self.onRightArrow = onRightArrow
            self.onLeftArrow = onLeftArrow
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      let keySinkView = self.keySinkView,
                      keySinkView.window?.isKeyWindow == true else { return event }
                switch event.keyCode {
                case 126:
                    return self.onUpArrow() ? nil : event
                case 125:
                    return self.onDownArrow() ? nil : event
                case 124:
                    return self.onRightArrow() ? nil : event
                case 123:
                    return self.onLeftArrow() ? nil : event
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            uninstall()
        }
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let previewNamespace: Namespace.ID
    let onSelect: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    preview
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
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .matchedGeometryEffect(
                    id: item.id,
                    in: previewNamespace,
                    isSource: true
                )
        } else {
            Image(systemName: item.kind.icon)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
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
