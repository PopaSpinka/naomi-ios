// Клиент сервера Наоми — ходит на те же /api/*, что и веб-вкладка.
// Адрес сервера задаётся в настройках приложения (шестерёнка) и хранится в UserDefaults.
// Удобнее указывать Мак по имени в домашней сети — `имя-мака.local` (см. «Общий доступ»
// в настройках macOS): имя стабильнее IP, роутер может выдать Маку другой адрес.
import Foundation
import UIKit

private extension Data {
    mutating func appendString(_ s: String) { append(Data(s.utf8)) }
}

enum NaomiAPI {
    static let defaultBase = "http://mac.local:8787"

    static var base: URL {
        let raw = UserDefaults.standard.string(forKey: "serverURL") ?? defaultBase
        return URL(string: raw) ?? URL(string: defaultBase)!
    }

    // Пропуск для доступа из большого мира (NAOMI_API_TOKEN на сервере).
    // Дома по Wi-Fi сервер пускает и без него.
    static var token: String {
        UserDefaults.standard.string(forKey: "apiToken")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func authorize(_ req: inout URLRequest) {
        if !token.isEmpty {
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
    }

    // ── Файлы со склада (фото в чате) ──

    // Адрес файла по относительному пути склада: сегменты кодируем по одному,
    // чтобы кириллица и пробелы в именах не ломали URL.
    static func fileURL(_ rel: String) -> URL {
        var url = base.appendingPathComponent("api/file")
        for part in rel.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    // Скачивает картинку склада с пропуском и ужимает до maxPixel по длинной стороне
    // (миниатюре хватает малого, полный экран — покрупнее; беречь память).
    static func loadImage(rel: String, maxPixel: CGFloat) async throws -> UIImage {
        var req = URLRequest(url: fileURL(rel))
        authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        let side = max(img.size.width, img.size.height)
        guard side > maxPixel else { return img }
        let scale = maxPixel / side
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        return await img.byPreparingThumbnail(ofSize: target) ?? img
    }

    // ── Загрузка вложения (POST /api/upload) ──

    struct UploadedAttachment: Decodable {
        let name: String          // относительный путь на складе — для истории и url
        let model: String         // абсолютный путь — его увидит мозг
        let origin: String?       // человеческое имя
        let dup: Bool?            // такой файл уже был на складе
    }

    static func upload(data: Data, filename: String) async throws -> UploadedAttachment {
        var req = URLRequest(url: base.appendingPathComponent("api/upload"))
        req.httpMethod = "POST"
        let boundary = "naomi-ios-" + UUID().uuidString
        req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        // CSRF-замок сервера: не-JSON POST без этого заголовка отбивается (403 forbidden).
        req.setValue("1", forHTTPHeaderField: "X-Naomi-Csrf")
        req.timeoutInterval = 300   // большие фото по Wi-Fi
        authorize(&req)

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(UploadedAttachment.self, from: respData)
    }

    // ── История (GET /api/history) — общая с вебом и телеграмом ──

    private struct HistoryResponse: Decodable { let messages: [HistoryMessage] }
    private struct HistoryMessage: Decodable {
        let role: String
        let content: String
        let files: [String]?
    }

    static func history() async throws -> [ChatMessage] {
        var req = URLRequest(url: base.appendingPathComponent("api/history"))
        authorize(&req)
        let (data, _) = try await URLSession.shared.data(for: req)
        let parsed = try JSONDecoder().decode(HistoryResponse.self, from: data)
        return parsed.messages.map {
            var m = ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.content)
            m.files = $0.files ?? []
            return m
        }
    }

    // ── Живой ответ (POST /api/chat, поток кадров) ──
    // Кадры ровно те, что сервер шлёт вебу: {t:"delta",d} — кусочек текста,
    // {t:"action",name} — Наоми что-то делает руками, {t:"tool",q} — вспоминает,
    // {t:"silent"} — сделала молча, {t:"error"} — мозг споткнулся.

    enum ChatEvent {
        case delta(String)
        case action(String)
        case file(String)    // Наоми прислала файл: относительный путь склада
        case silent
        case failure
    }

    private struct Frame: Decodable {
        let t: String
        let d: String?
        let name: String?
        let q: String?
    }

    static func send(_ text: String, attachments: [UploadedAttachment] = []) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    authorize(&req)
                    // Пауза между кадрами: сервер шлёт пульс каждые 15 сек, так что 120 — с запасом.
                    req.timeoutInterval = 120
                    let body: [String: Any] = [
                        "messages": [["role": "user", "content": text]],
                        "attachments": attachments.map { [
                            "name": $0.name,
                            "model": $0.model,
                            "origin": $0.origin ?? $0.name,
                            "dup": $0.dup ?? false,
                        ] },
                    ]
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
                        case "file": if let rel = frame.name, !rel.isEmpty { continuation.yield(.file(rel)) }
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
