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
    // чтобы кириллица и пробелы в именах не ломали URL. trash — файл из корзины
    // (склад его уже не отдаёт, у корзины свой маршрут).
    static func fileURL(_ rel: String, trash: Bool = false) -> URL {
        var url = base.appendingPathComponent(trash ? "api/trash/file" : "api/file")
        for part in rel.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    // Скачивает картинку склада с пропуском и ужимает до maxPixel по длинной стороне
    // (миниатюре хватает малого, полный экран — покрупнее; беречь память).
    static func loadImage(rel: String, maxPixel: CGFloat, trash: Bool = false) async throws -> UIImage {
        var req = URLRequest(url: fileURL(rel, trash: trash))
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
        let segments: [HistorySegment]?   // слои «сложного» хода (пишет бэкенд, см. chat.js)
    }
    // Слой хода из истории: text | action | file — зеркало кадров живого стрима.
    private struct HistorySegment: Decodable {
        let kind: String
        let text: String?    // text: кусок ответа между делами
        let name: String?    // action: имя инструмента; file: путь на складе
        let q: String?       // action: запрос веб-поиска (WebSearch)
        let sub: Int?        // 1 — дело фоновой помощницы
    }

    static func history() async throws -> [ChatMessage] {
        var req = URLRequest(url: base.appendingPathComponent("api/history"))
        authorize(&req)
        let (data, _) = try await URLSession.shared.data(for: req)
        let parsed = try JSONDecoder().decode(HistoryResponse.self, from: data)
        var out: [ChatMessage] = []
        for m in parsed.messages {
            // «Сложный» ход Наоми хранится слоями — разворачиваем в те же ряды, что рисовал
            // живой стрим: застывшие плашки дел и файлы между текст-пузырями (как веб после F5).
            if m.role == "assistant", let rows = layerRows(m.segments) {
                out.append(contentsOf: rows)
            } else {
                var msg = ChatMessage(role: m.role == "user" ? .user : .assistant, text: m.content)
                msg.files = m.files ?? []
                out.append(msg)
            }
        }
        return out
    }

    // Слои серверной истории → ряды ленты (порт histSegs из веба). Подряд идущие дела
    // схлопываются до последней подписи — ровно как выглядел живой ход (цепочка дел
    // крутится одной плашкой и застывает на последнем ярлыке). Файл — своим рядом,
    // общий список files сообщения тогда не нужен (файлы уже стоят по местам).
    // Слоёв нет или все пустые — nil, ход отрисуется обычным путём (content + files).
    private static func layerRows(_ segs: [HistorySegment]?) -> [ChatMessage]? {
        guard let segs, !segs.isEmpty else { return nil }
        var out: [ChatMessage] = []
        for s in segs {
            switch s.kind {
            case "text":
                let t = s.text ?? ""
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ChatMessage(role: .assistant, text: t))
                }
            case "action":
                let label = ActionLabels.label(name: s.name ?? "", q: s.q, sub: s.sub == 1)
                if let i = out.indices.last, out[i].kind == .action {
                    out[i].text = label
                } else {
                    out.append(ChatMessage(role: .assistant, text: label, kind: .action))
                }
            case "file":
                if let name = s.name, !name.isEmpty {
                    var msg = ChatMessage(role: .assistant, text: "")
                    msg.files = [name]
                    out.append(msg)
                }
            default:
                break
            }
        }
        return out.isEmpty ? nil : out
    }

    // ── Поручения: напоминания / заметки / идеи — та же база, что видит Наоми ──
    // Карточки живут в core/orders.js; сторож проверяет условия на сервере.
    // Приложению хватает читаемых полей — trig/action в UI не разбираем.

    struct Order: Decodable {
        let id: Int
        let kind: String?         // remind | note | idea | auto
        let title: String?
        let status: String?       // active | paused | done | trash
        let pendingAck: Int?      // 1 = сработало/висит — ждёт галочку «сделал»
        let humanWhen: String?    // условие по-человечески («каждый день в 09:00»)
        let humanDo: String?      // действие по-человечески (у автоматики)
        let fireCount: Int?
        let lastFired: Int?
        let notify: Int?          // автоматика: писать в чат при срабатывании
        let repeatFlag: Int?      // постоянное (repeat — слово Swift, потому Flag)

        // Ключи явные: repeat не назвать полем, а остальные — snake_case сервера.
        enum CodingKeys: String, CodingKey {
            case id, kind, title, status, notify
            case pendingAck = "pending_ack"
            case humanWhen = "human_when"
            case humanDo = "human_do"
            case fireCount = "fire_count"
            case lastFired = "last_fired"
            case repeatFlag = "repeat"
        }
    }

    private struct OrdersResponse: Decodable { let orders: [Order] }

    // Четыре вкладки Поручений (идеи/заметки/напоминалки/автоматика) тянут ОДИН и тот
    // же список — каждая фильтрует по своему виду уже у себя. На холодном старте и на
    // общем 60-секундном тике это било 8 одинаковых запросов разом. Склейка вызовов,
    // летящих в один момент (OrdersInflight), сводит их к одному походу в сеть. Кэша
    // по времени тут НЕТ намеренно: после действия над карточкой список должен
    // перечитаться сразу, без застоя.
    static func orders(status: String) async throws -> [Order] {
        try await OrdersInflight.shared.get(status: status)
    }

    fileprivate static func fetchOrders(status: String) async throws -> [Order] {
        var comps = URLComponents(url: base.appendingPathComponent("api/orders"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "status", value: status)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(OrdersResponse.self, from: data).orders
    }

    // Действия над поручениями: create/update/trash/restore/purge/ack/reopen —
    // те же ручки, что жмёт веб; тело — JSON, ответ не разбираем (после — reload).
    static func orderPost(_ path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Naomi-Csrf")
        req.timeoutInterval = 15
        authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    // ── Файлы: склад и корзина, как вкладка в вебе ──
    // Склад отдаёт файлы новыми сверху с описью из картотеки; корзина — мягкое
    // удаление (файл и карточка уезжают вместе, восстановление возвращает оба).

    struct FileEntry: Decodable {
        let rel: String           // относительный путь склада — ключ всех действий
        let date: String?         // папка-день «2026-07-13»
        let time: String?         // «14:32» из имени файла
        let name: String?         // человеческое имя
        let kind: String?         // photo | doc
        let size: Int?            // байты
        let channel: String?      // web | telegram | inbox
        let descr: String?        // опись из картотеки (нет — файл «без карточки»)
        let deletedTs: Int?       // только у корзины: когда удалён
    }

    private struct FilesResponse: Decodable { let files: [FileEntry] }

    private static func fetchFiles(_ path: String) async throws -> [FileEntry] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 15
        authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase   // deleted_ts → deletedTs
        return try dec.decode(FilesResponse.self, from: data).files
    }

    static func files() async throws -> [FileEntry] { try await fetchFiles("api/files") }
    static func trashFiles() async throws -> [FileEntry] { try await fetchFiles("api/trash") }

    // Действие над файлом: api/files/delete (в корзину), api/files/restore,
    // api/files/annotate (Наоми рассмотрит файл и занесёт карточку).
    static func fileAction(_ path: String, rel: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Naomi-Csrf")
        req.timeoutInterval = 15
        authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["rel": rel])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    // Очистка корзины — единственное необратимое действие склада.
    static func emptyTrash() async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/trash/empty"))
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Naomi-Csrf")
        req.timeoutInterval = 15
        authorize(&req)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    // ── Таймлайн дома (GET /api/timeline) — та же лента переходов, что в вебе ──
    // Сервер отдаёт события новые-сверху и уже всё подписывает: жирную часть,
    // деталь, кто сделал (Автоматика/Наоми) и длительность состояния.

    struct TimelineEvent: Decodable {
        let ts: Int               // unix-секунды события
        let module: String?       // группа для цвета точки («Присутствие», «Телевизор»...)
        let label: String?        // жирная часть («Слава», «Кондиционер»)
        let detail: String?       // что случилось («пришёл домой», «выключен»)
        let sep: String?          // разделитель между ними (сервер шлёт «—»)
        let source: String?       // кто сделал — рисуется чипом («Автоматика»)
        let durLabel: String?     // «17 минут» — сколько длилось состояние

        enum CodingKeys: String, CodingKey {
            case ts, module, label, detail, sep, source
            case durLabel = "dur_label"
        }
    }

    private struct TimelineResponse: Decodable { let events: [TimelineEvent] }

    static func timeline() async throws -> [TimelineEvent] {
        var req = URLRequest(url: base.appendingPathComponent("api/timeline"))
        req.timeoutInterval = 10
        authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(TimelineResponse.self, from: data).events
    }

    // ── Умный дом (GET/POST /api/home) — та же панель, что в вебе ──
    // GET — живой снимок всех модулей; POST с патчем ({ac:{on:true}}, {tv:{on:false}},
    // {vacuum:{do:"dock"}}) — команда железу, в ответ сразу свежий снимок.

    struct HomeState: Decodable {
        struct Weather: Decodable {
            let ok: Bool?
            let stale: Bool?
            let feels: Int?
            let condition: String?
            let windMs: Double?
            let gustMs: Double?
            let rainProb: Int?
            let uvBand: String?
            let isDay: Bool?
        }
        struct AC: Decodable {
            let online: Bool?
            let on: Bool?
            let temp: Int?          // целевая
            let ambient: Double?    // датчик в гостиной
            let mode: String?       // cool | dry | eco | fan
            let fan: String?        // auto | low | middle | high
            let air: String?        // качество воздуха по-русски
        }
        struct Vacuum: Decodable {
            let online: Bool?
            let battery: Int?
            let stateRu: String?    // «заряжается», «пылесосит»...
            let cleanKind: String?  // вид текущей уборки (nil — не убирается)
            let docked: Bool?
        }
        struct TV: Decodable {
            let online: Bool?
            let on: Bool?
        }
        struct Person: Decodable { let home: Bool? }

        let weather: Weather?
        let ac: AC?
        let vacuum: Vacuum?
        let tv: TV?
        let presence: [String: Person]?
    }

    private static func decodeHome(_ data: Data) throws -> HomeState {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase   // wind_ms → windMs и т.п.
        return try dec.decode(HomeState.self, from: data)
    }

    static func home() async throws -> HomeState {
        var req = URLRequest(url: base.appendingPathComponent("api/home"))
        req.timeoutInterval = 10
        authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decodeHome(data)
    }

    static func patchHome(_ patch: [String: Any]) async throws -> HomeState {
        var req = URLRequest(url: base.appendingPathComponent("api/home"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Naomi-Csrf")
        req.timeoutInterval = 15
        authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: patch)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decodeHome(data)
    }

    // ── Живой ответ (POST /api/chat, поток кадров) ──
    // Кадры ровно те, что сервер шлёт вебу: {t:"delta",d} — кусочек текста,
    // {t:"action",name} — Наоми что-то делает руками, {t:"tool",q} — ищет в интернете,
    // {t:"break"} — мозг начал новый текст-блок (текущий пузырь закрыть, следующий
    // текст — новым слоем), {t:"file",name} — прислала файл, {t:"silent"} — сделала
    // молча, {t:"error"} — мозг споткнулся. У action/tool бывает sub=1 — это дело
    // фоновой помощницы, подпись рисуем с приставкой «помощница · ».

    enum ChatEvent {
        case delta(String)
        case action(String)  // готовая подпись плашки («работаю в терминале», «помощница · …»)
        case textBreak       // новый текст-блок: текущий пузырь застывает своим слоем
        case file(String)    // Наоми прислала файл: относительный путь склада
        case silent
        case failure
    }

    private struct Frame: Decodable {
        let t: String
        let d: String?
        let name: String?
        let q: String?
        let sub: Int?        // 1 — кадр фоновой помощницы
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
                        "channel": "ios",   // Наоми видит в сводке, что Слава пишет из приложения
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
                        case "action": continuation.yield(.action(ActionLabels.label(name: frame.name ?? "", sub: frame.sub == 1)))
                        case "tool": continuation.yield(.action(ActionLabels.label(name: "WebSearch", q: frame.q, sub: frame.sub == 1)))
                        case "break": continuation.yield(.textBreak)
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

// Склейка одновременных запросов Поручений: если несколько вкладок просят один и тот
// же список в один момент, все ждут ОДНОГО похода в сеть. Держится только «в полёте» —
// как только запрос завершился, следующий вызов идёт свежим (никакого устаревания
// после действий над карточками). На главном потоке живёт лишь дешёвая бухгалтерия
// словаря; сам запрос и разбор JSON идут в стороне (fetchOrders — не на MainActor).
@MainActor
private final class OrdersInflight {
    static let shared = OrdersInflight()
    private var tasks: [String: Task<[NaomiAPI.Order], Error>] = [:]

    func get(status: String) async throws -> [NaomiAPI.Order] {
        if let running = tasks[status] { return try await running.value }
        let task = Task { try await NaomiAPI.fetchOrders(status: status) }
        tasks[status] = task
        defer { tasks[status] = nil }
        return try await task.value
    }
}
