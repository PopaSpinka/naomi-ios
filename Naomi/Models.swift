// Сообщение в ленте чата. История с сервера и живые сообщения приводятся к одному виду.
import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    // Обычный пузырь с текстом или служебная плашка «что Наоми делает прямо сейчас».
    // Плашки живут только в живом ходе — история с сервера их не хранит (как веб после F5).
    enum Kind { case text, action }

    let id: UUID
    let role: Role
    let kind: Kind
    var text: String
    var isStreaming = false      // ответ ещё капает по буквам
    var isError = false          // не дозвонились / сервер ответил ошибкой
    var isLive = false           // плашка действия ещё крутится (спиннер); застыла — галочка

    init(role: Role, text: String, kind: Kind = .text) {
        self.id = UUID()
        self.role = role
        self.kind = kind
        self.text = text
    }
}
