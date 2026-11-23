import AppKit
import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        case text(String)
        case image(Data)
        case files([URL])

        private enum CodingKeys: String, CodingKey { case kind, value }
        private enum Kind: String, Codable { case text, image, files }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .text: self = .text(try container.decode(String.self, forKey: .value))
            case .image: self = .image(try container.decode(Data.self, forKey: .value))
            case .files: self = .files(try container.decode([URL].self, forKey: .value))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(Kind.text, forKey: .kind)
                try container.encode(text, forKey: .value)
            case .image(let data):
                try container.encode(Kind.image, forKey: .kind)
                try container.encode(data, forKey: .value)
            case .files(let urls):
                try container.encode(Kind.files, forKey: .kind)
                try container.encode(urls, forKey: .value)
            }
        }
    }

    let id: UUID
    let createdAt: Date
    let content: Content

    init(id: UUID = UUID(), createdAt: Date = Date(), content: Content) {
        self.id = id
        self.createdAt = createdAt
        self.content = content
    }

    var searchText: String {
        switch content {
        case .text(let text): return text
        case .image: return "image 图片"
        case .files(let urls): return urls.map { $0.lastPathComponent }.joined(separator: " ")
        }
    }

    var title: String {
        switch content {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image:
            return "Image"
        case .files(let urls):
            if urls.count == 1 { return urls[0].lastPathComponent }
            return "\(urls.count) files"
        }
    }

    var detail: String? {
        switch content {
        case .text(let text):
            let lines = text.components(separatedBy: .newlines)
            return lines.count > 1 ? lines.dropFirst().joined(separator: " ") : nil
        case .image(let data):
            guard let image = NSImage(data: data) else { return nil }
            return "\(Int(image.size.width)) × \(Int(image.size.height))"
        case .files(let urls):
            return urls.count > 1 ? urls.map { $0.lastPathComponent }.joined(separator: ", ") : urls.first?.deletingLastPathComponent().path
        }
    }

    var deduplicationKey: String {
        switch content {
        case .text(let text): return "text:\(text)"
        case .image(let data): return "image:\(data.hashValue)"
        case .files(let urls): return "files:" + urls.map { $0.standardizedFileURL.path }.joined(separator: "\u{0}")
        }
    }
}
