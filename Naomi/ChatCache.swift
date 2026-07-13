// Слепок переписки на телефоне: последние сообщения лежат в файле, и при холодном
// старте чат появляется мгновенно — сеть потом тихо догоняет и обновляет слепок.
import Foundation

enum ChatCache {
    // Хвост переписки; полная история живёт на сервере.
    static let limit = 300

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-cache.json")
    }

    private struct StoredMessage: Codable {
        let role: String
        let text: String
        let files: [String]?
    }

    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data)
        else { return [] }
        return stored.map {
            var m = ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text)
            m.files = $0.files ?? []
            return m
        }
    }

    static func save(_ messages: [ChatMessage]) {
        // Только переписка (текст и фото): плашки дел и ошибки — живое, в слепок не идут.
        let stored = messages
            .filter { $0.kind == .text && !$0.isError && (!$0.text.isEmpty || !$0.files.isEmpty) }
            .suffix(limit)
            .map { StoredMessage(
                role: $0.role == .user ? "user" : "assistant",
                text: $0.text,
                files: $0.files.isEmpty ? nil : $0.files
            ) }
        guard let data = try? JSONEncoder().encode(Array(stored)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
