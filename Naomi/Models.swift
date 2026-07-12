// Сообщение в ленте чата. История с сервера и живые сообщения приводятся к одному виду.
import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    var actions: [String] = []   // плашки действий Наоми («включаю кондиционер» и т.п.)
    var isStreaming = false      // ответ ещё капает по буквам
    var isError = false          // не дозвонились / сервер ответил ошибкой

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
}
