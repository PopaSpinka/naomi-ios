// Клиент сервера Наоми — ходит на те же /api/*, что и веб-вкладка.
// Адрес сервера задаётся в настройках приложения (шестерёнка) и хранится в UserDefaults.
// Удобнее указывать Мак по имени в домашней сети — `имя-мака.local` (см. «Общий доступ»
// в настройках macOS): имя стабильнее IP, роутер может выдать Маку другой адрес.
import Foundation

enum NaomiAPI {
    static let defaultBase = "http://mac.local:8787"

    static var base: URL {
        let raw = UserDefaults.standard.string(forKey: "serverURL") ?? defaultBase
        return URL(string: raw) ?? URL(string: defaultBase)!
    }

    // ── История (GET /api/history) — общая с вебом и телеграмом ──

    private struct HistoryResponse: Decodable { let messages: [HistoryMessage] }
    private struct HistoryMessage: Decodable {
        let role: String
        let content: String
    }

    static func history() async throws -> [ChatMessage] {
        let url = base.appendingPathComponent("api/history")
        let (data, _) = try await URLSession.shared.data(from: url)
        let parsed = try JSONDecoder().decode(HistoryResponse.self, from: data)
        return parsed.messages.map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.content)
        }
    }

    // ── Живой ответ (POST /api/chat, поток кадров) ──
    // Кадры ровно те, что сервер шлёт вебу: {t:"delta",d} — кусочек текста,
    // {t:"action",name} — Наоми что-то делает руками, {t:"tool",q} — вспоминает,
    // {t:"silent"} — сделала молча, {t:"error"} — мозг споткнулся.

    enum ChatEvent {
        case delta(String)
        case action(String)
        case silent
        case failure
    }

    private struct Frame: Decodable {
        let t: String
        let d: String?
        let name: String?
        let q: String?
    }

    static func send(_ text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // Пауза между кадрами: сервер шлёт пульс каждые 15 сек, так что 120 — с запасом.
                    req.timeoutInterval = 120
                    let body = ["messages": [["role": "user", "content": text]]]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let frame = try? JSONDecoder().decode(Frame.self, from: Data(line.dropFirst(6).utf8))
                        else { continue }   // пульсы «: hb» и служебные строки пропускаем
                        switch frame.t {
                        case "delta": continuation.yield(.delta(frame.d ?? ""))
                        case "action": continuation.yield(.action(frame.name ?? "делаю"))
                        case "tool": continuation.yield(.action("вспоминаю"))
                        case "silent": continuation.yield(.silent)
                        case "error": continuation.yield(.failure)
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
