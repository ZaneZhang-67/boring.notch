import Foundation

struct ClipboardRepresentation: Equatable, Sendable {
    static let securityScopedBookmarkType = "com.boringnotch.clipboard.security-scoped-bookmark"

    let typeIdentifier: String
    let data: Data
}

struct ClipboardPayloadItem: Equatable, Sendable {
    let representations: [ClipboardRepresentation]
}

struct ClipboardRefreshedBookmark: Sendable {
    let itemIndex: Int
    let data: Data
}

struct ClipboardPayload: Equatable, Sendable {
    let items: [ClipboardPayloadItem]
    let sourceBundleIdentifier: String?

    init(items: [ClipboardPayloadItem], sourceBundleIdentifier: String? = nil) {
        self.items = items
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }

    var byteCount: Int64 {
        items.reduce(0) { itemTotal, item in
            itemTotal + item.representations.reduce(0) { $0 + Int64($1.data.count) }
        }
    }

    var typeIdentifiers: [String] {
        Array(Set(items.flatMap { item in
            item.representations.compactMap { representation in
                representation.typeIdentifier == ClipboardRepresentation.securityScopedBookmarkType
                    ? nil
                    : representation.typeIdentifier
            }
        })).sorted()
    }
}

enum ClipboardContentKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case html
    case image
    case files
    case folder
    case url
    case other
}

struct ClipboardHistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ClipboardContentKind
    let title: String
    let subtitle: String?
    let searchText: String
    let createdAt: Date
    let lastUsedAt: Date
    let isPinned: Bool
    let byteCount: Int64
    let itemCount: Int
    let typeIdentifiers: [String]
    let thumbnailData: Data?
    let sourceBundleIdentifier: String?
}
