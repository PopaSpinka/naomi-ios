// Сообщение в ленте чата. История с сервера и живые сообщения приводятся к одному виду.
import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    // Пузырь с текстом, плашка «что Наоми делает» или «думаю» (три точки).
    // Плашки переживают перезапуск: сервер хранит слои сложного хода (segments),
    // история разворачивает их обратно в ряды ленты (как веб после F5).
    enum Kind { case text, action, thinking }

    let id: UUID
    let role: Role
    let kind: Kind
    var text: String
    var files: [String] = []     // вложения: относительные пути на складе сервера
    var isStreaming = false      // ответ ещё капает по буквам
    var isError = false          // не дозвонились / сервер ответил ошибкой
    var isLive = false           // плашка действия ещё живая (волна по тексту); застыла — тихий текст

    init(role: Role, text: String, kind: Kind = .text) {
        self.id = UUID()
        self.role = role
        self.kind = kind
        self.text = text
    }
}

// Имя инструмента → человеческая подпись плашки «что Наоми делает» — та же карта,
// что в вебе (ACTION_LABELS в app.jsx). Неизвестное имя → нейтральное «выполняю команду».
enum ActionLabels {
    private static let map: [String: String] = [
        // Инструменты самой Наоми (mcp__naomi__* — сервер шлёт короткое имя)
        "create_order": "записываю заметку",
        "update_order": "правлю заметку",
        "cancel_order": "убираю заметку",
        "list_orders": "просматриваю заметки",
        "home_history": "поднимаю историю дома",
        "set_ac": "настраиваю кондиционер",
        "start_vacuum": "запускаю пылесос",
        "start_mop": "запускаю мойку пола",
        "start_combo": "запускаю уборку",
        "dock_vacuum": "отправляю пылесос на базу",
        "weather_forecast": "смотрю прогноз погоды",
        "manage_automation": "разбираюсь с поручением",
        "restart_naomi": "перезапускаю себя",
        "search_archive": "ищу в архиве",
        "send_file": "достаю файл из архива",
        "remember_fact": "запоминаю",
        "search_facts": "вспоминаю",
        "update_fact": "обновляю память",
        "forget_fact": "забываю",
        "read_document": "перечитываю документ",
        "recall_memory": "вспоминаю",
        // Инструменты мозга (Claude Agent SDK)
        "Bash": "работаю в терминале",
        "Read": "читаю файл",
        "Write": "пишу файл",
        "Edit": "правлю файл",
        "Glob": "ищу файлы",
        "Grep": "ищу по файлам",
        "WebFetch": "открываю страницу",
        "NotebookEdit": "правлю блокнот",
        "Task": "веду список задач",
        "TaskCreate": "записываю задачу",
        "TaskUpdate": "обновляю задачу",
        "TaskList": "сверяюсь со списком задач",
        "TaskGet": "сверяюсь с задачей",
        "TodoWrite": "веду список дел",
        "Agent": "запускаю помощницу",
        "Monitor": "слежу за процессом",
        "AskUserQuestion": "формулирую вопрос",
        "AgentDone": "помощница вернулась",
        "ToolSearch": "подбираю инструменты",
    ]

    // Подпись плашки по кадру/слою (segLabel из веба): поиск — с текстом запроса,
    // дела фоновой помощницы (sub=1) — с приставкой «помощница · ».
    static func label(name: String, q: String? = nil, sub: Bool = false) -> String {
        let base = name == "WebSearch"
            ? "ищу в интернете: «\(q ?? "")»"
            : (map[name] ?? "выполняю команду")
        return (sub ? "помощница · " : "") + base
    }
}
