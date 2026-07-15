// Напоминалки / Заметки / Идеи — один экран с тремя «скоупами», как OrdersPanel
// в вебе (frontend/app.jsx): одна база поручений, у каждого вида своя вкладка и
// своя корзина. Напоминания — секция «Сделать» (сработавшие, ждут галочку) и
// «Выполненные» под фолдом; заметки — стикеры с галочкой «снял»; идеи — копилка,
// её пишет сама Наоми (кнопки создания нет). Текст правится прямо в карточке —
// незаметно, без окошек (принцип Славы); тап мимо — сохранилось.
import SwiftUI

enum OrdersScope {
    case reminds, notes, ideas, auto

    var kind: String {
        switch self {
        case .reminds: "remind"
        case .notes: "note"
        case .ideas: "idea"
        case .auto: "auto"
        }
    }
    var navTitle: String {
        switch self {
        case .reminds: "Напоминалки"
        case .notes: "Заметки"
        case .ideas: "Идеи"
        case .auto: "Автоматика"
        }
    }
    var tabLabel: String {
        switch self {
        case .reminds: "Напоминания"
        case .notes: "Заметки"
        case .ideas: "Идеи"
        case .auto: "Правила"
        }
    }
    var newLabel: String {
        switch self {
        case .reminds: "Новое напоминание"
        case .notes: "Новая заметка"
        case .ideas: ""   // идеи создаёт Наоми — кнопки нет, как в вебе
        case .auto: "Новое правило"
        }
    }
    var emptyText: String {
        switch self {
        case .reminds: "напоминаний нет — попроси Наоми или создай тут"
        case .notes: "заметок нет — попроси Наоми или создай тут"
        case .ideas: "копилка идей пуста — расскажи Наоми идею, она запишет суть"
        case .auto: "правил автоматики нет — попроси Наоми или создай тут"
        }
    }
    var purgeScope: String {
        switch self {
        case .reminds: "reminds"
        case .notes: "notes"
        case .ideas: "ideas"
        case .auto: "auto"
        }
    }
}

struct OrdersView: View {
    let scope: OrdersScope
    // Для Идей корзина живёт снаружи: кнопкой-стеклом справа (эта вьюха её рисует),
    // а шторка в RootView становится «назад». У остальных видов — свои чипы внизу.
    var trashOpen: Binding<Bool>? = nil
    // Вкладка сейчас на экране? Экран живёт в стопке RootView всегда — скрытый
    // тоже обновляется, но редким тиком (карточки тёплые к моменту переключения).
    var active = true

    @Environment(\.naomiTopInset) private var topInset

    private enum Tab { case list, trash }

    @State private var tab: Tab = .list
    @State private var orders: [NaomiAPI.Order]?   // nil = ещё грузится
    @State private var trash: [NaomiAPI.Order] = []
    @State private var failed = false
    @State private var creating = false
    @State private var showDone = false            // «Выполненные» спрятаны под фолд
    @State private var confirmPurge = false
    @State private var form = OrderForm()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.naomiBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // У Идей в списке нет панели вкладок — только сам список; в корзине
                    // панель нужна ради «Удалить всё». У остальных видов — всегда.
                    if scope != .ideas || showingTrash {
                        tabsBar
                    }
                    list
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
        }
        // Кнопка-корзина Идей — парит стеклом справа, вровень с кнопкой шторки
        // слева (как шестерёнка в чате). В корзине прячется, а шторка — «назад».
        .overlay(alignment: .topTrailing) {
            if scope == .ideas && !showingTrash {
                GlassCircleButton(systemName: "trash") {
                    // Без анимации: анимированная смена list↔trash «схлопывала» текст
                    // карточек (SwiftUI гнал высоту от нуля). Мгновенно — как смена вкладки.
                    trashOpen?.wrappedValue = true
                }
                .padding(.trailing, 18)
                .padding(.top, topInset + 4)
            }
        }
        // Сторож живёт своей жизнью на сервере — карточки должны быть свежими.
        // Открытая вкладка поллит как веб (5 сек), спрятанная — раз в минуту:
        // к переключению всё готово. Смена active перезапускает задачу.
        .task(id: active) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(active ? 5 : 60))
            }
        }
        .alert("Очистить корзину насовсем?", isPresented: $confirmPurge) {
            Button("Удалить всё", role: .destructive) { post("api/orders/purge", ["scope": scope.purgeScope]) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это необратимо: карточки пропадут навсегда.")
        }
    }

    // ── Данные ──

    // Каждая вкладка видит только СВОЙ вид карточек.
    private func mine(_ o: NaomiAPI.Order) -> Bool { o.kind == scope.kind }
    private var all: [NaomiAPI.Order] { (orders ?? []).filter(mine) }
    private var myTrash: [NaomiAPI.Order] { trash.filter(mine) }

    private func isTodo(_ o: NaomiAPI.Order) -> Bool { (o.pendingAck ?? 0) != 0 }

    // Счётчик вкладки: у напоминаний — живые и сработавшие, у правил — живые,
    // у остальных — активные.
    private var mainCount: Int {
        switch scope {
        case .reminds: all.filter { $0.status == "active" || $0.status == "paused" || isTodo($0) }.count
        case .auto: all.filter { $0.status == "active" || $0.status == "paused" }.count
        case .notes, .ideas: all.filter { $0.status == "active" }.count
        }
    }

    // Корзина/список: у Идей — из внешнего биндинга (кнопка-стекло + «назад»),
    // у остальных — из внутренней вкладки-чипа.
    private var showingTrash: Bool { trashOpen?.wrappedValue ?? (tab == .trash) }

    // Заголовок по центру. У Идей счётчик переехал сюда из чипов; в корзине —
    // «Корзина · N» вместо снятого чипа корзины.
    private var titleText: String {
        guard scope == .ideas else { return scope.navTitle }
        if showingTrash { return "Корзина" + (myTrash.isEmpty ? "" : " · \(myTrash.count)") }
        return "Идеи" + (mainCount > 0 ? " · \(mainCount)" : "")
    }

    private func load() async {
        do {
            async let a = NaomiAPI.orders(status: "all")
            async let b = NaomiAPI.orders(status: "trash")
            let (oa, tb) = try await (a, b)
            orders = oa
            trash = tb
            failed = false
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func post(_ path: String, _ body: [String: Any]) {
        Task {
            do { try await NaomiAPI.orderPost(path, body: body) } catch { failed = true }
            await load()
        }
    }

    // ── Шапка: вкладки + корзина + создание ──

    private var tabsBar: some View {
        HStack(spacing: 8) {
            // У Идей чипов нет: счётчик — в заголовке, корзина — кнопкой-стеклом.
            if scope != .ideas {
                tabChip(scope.tabLabel + (mainCount > 0 ? " · \(mainCount)" : ""), on: !showingTrash) { tab = .list }
                tabChip("Корзина" + (myTrash.isEmpty ? "" : " · \(myTrash.count)"), on: showingTrash) { tab = .trash }
            }
            Spacer()
            if showingTrash && !myTrash.isEmpty {
                Button("Удалить всё") { confirmPurge = true }
                    .font(nfont(14.5))
                    .foregroundStyle(Color.naomiErr)
                    .buttonStyle(.plain)
            }
            if !showingTrash && scope != .ideas {
                Button(creating ? "Закрыть" : scope.newLabel) {
                    withAnimation(.snappy(duration: 0.2)) { creating.toggle() }
                }
                .font(nfont(14.5))
                .foregroundStyle(Color.naomiAccent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func tabChip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(nfont(15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.primary : Color.naomiMuted)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background {
                    if on { Capsule().fill(Color.naomiBubble) }
                }
        }
        .buttonStyle(.plain)
    }

    // ── Список ──

    @ViewBuilder
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if failed { waitText("сервер не отвечает", err: true) }

                if creating && !showingTrash {
                    OrderCreateForm(scope: scope, form: $form) {
                        createOrder()
                    } onCancel: {
                        withAnimation(.snappy(duration: 0.2)) { creating = false }
                    }
                }

                if orders == nil {
                    if !failed { waitText("загружаю…") }
                } else if showingTrash {
                    trashList
                } else {
                    mainList
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var mainList: some View {
        // Секции — как в вебе: сработавшие → живые → «Выполненные» под фолдом.
        let todo = scope == .reminds ? all.filter { isTodo($0) } : []
        let stickers = scope == .notes ? all.filter { $0.status == "active" } : []
        let waiting = (scope == .reminds || scope == .auto) ? all.filter { !isTodo($0) && ($0.status == "active" || $0.status == "paused") } : []
        let ideas = scope == .ideas ? all.filter { $0.status == "active" } : []
        let done = scope != .ideas ? all.filter { !isTodo($0) && $0.status == "done" } : []

        if todo.isEmpty && stickers.isEmpty && waiting.isEmpty && ideas.isEmpty && done.isEmpty {
            waitText(scope.emptyText)
        }
        ForEach(ideas, id: \.id) { card($0) }
        if !todo.isEmpty {
            sectionHeader("Сделать")
            ForEach(todo, id: \.id) { card($0) }
        }
        ForEach(stickers, id: \.id) { card($0) }
        if scope == .auto && !waiting.isEmpty {
            sectionHeader("Правила")
        }
        ForEach(waiting, id: \.id) { card($0) }
        if !done.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showDone.toggle() }
            } label: {
                sectionHeader((showDone ? "▾ " : "▸ ") + "Выполненные · \(done.count)")
            }
            .buttonStyle(.plain)
            if showDone {
                ForEach(done, id: \.id) { card($0) }
            }
        }
    }

    @ViewBuilder
    private var trashList: some View {
        if myTrash.isEmpty {
            waitText("корзина пуста")
        } else {
            ForEach(myTrash, id: \.id) { card($0) }
        }
    }

    private func card(_ o: NaomiAPI.Order) -> some View {
        OrderCardView(o: o, todo: isTodo(o) && o.status != "trash", onPost: post)
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .textCase(.uppercase)
            .font(nfont(12, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(Color.naomiMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func waitText(_ s: String, err: Bool = false) -> some View {
        Text(s)
            .font(nfont(14.5))
            .foregroundStyle(err ? Color.naomiErr : Color.naomiMuted)
            .padding(.vertical, 4)
    }

    private func createOrder() {
        let title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // Заметка — без условия; напоминание и правило собирают триггер из формы
        // (как orderTrig в вебе), правило — ещё и действие.
        let trig: [String: Any]? = scope == .notes ? ["type": "none"] : form.buildTrig()
        guard let trig else { return }
        var body: [String: Any] = [
            "kind": scope.kind,
            "title": title,
            "trig": trig,
            "repeat": ((scope == .reminds || scope == .auto) && form.repeatOn) ? 1 : 0,
            "notify": scope == .auto ? (form.notifyOn ? 1 : 0) : 1,
        ]
        if scope == .auto {
            guard let action = form.buildAction() else { return }   // правило без действия не бывает
            body["action"] = action
        }
        post("api/orders/create", body)
        withAnimation(.snappy(duration: 0.2)) { creating = false }
        form.title = ""
    }
}

// ── Карточка поручения ──

private struct OrderCardView: View {
    let o: NaomiAPI.Order
    let todo: Bool
    var onPost: (String, [String: Any]) -> Void

    // Правка прямо в тексте: черновик у карточки свой, серверный текст подъезжает
    // только пока не редактируем (иначе полл раз в 5 сек дёргал бы курсор).
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var inTrash: Bool { o.status == "trash" }
    private var faded: Bool { !todo && o.status != "active" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if o.kind == "auto" {
                Text("автоматика" + ((o.repeatFlag ?? 0) != 0 ? " · постоянная" : ""))
                    .font(nfont(11))
                    .foregroundStyle(Color.naomiMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            HStack(alignment: .top, spacing: 10) {
                TextField("", text: $draft, axis: .vertical)
                    .font(nfont(15.5))
                    .focused($editing)
                    .disabled(inTrash)   // в корзине не правим — только восстановить
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            if o.kind == "remind" || o.kind == "auto" {
                meta
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.naomiBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            // Сработавшее — с терракотовой рамкой: просит галочку.
            if todo {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.naomiAccent.opacity(0.45), lineWidth: 1.5)
            }
        }
        .opacity(faded ? 0.55 : 1)
        .onAppear { draft = prettifyCard(o.title ?? "") }
        .onChange(of: o.title) { _, t in
            if !editing { draft = prettifyCard(t ?? "") }
        }
        .onChange(of: editing) { _, isOn in
            if !isOn { save() }
        }
        .onDisappear { if editing { save() } }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let orig = prettifyCard(o.title ?? "")
        if t.isEmpty {
            draft = orig   // пусто — вернуть как было
        } else if t != orig {
            onPost("api/orders/update", ["id": o.id, "title": t])   // POST только при реальной правке
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if todo {
                // «Сделано ✓» — снять с колокольчика / стикер со стены.
                actButton("checkmark", tint: Color(light: 0x3E9F77, dark: 0x56CCA0)) {
                    onPost("api/orders/ack", ["id": o.id])
                }
            }
            if inTrash {
                actButton("arrow.uturn.backward") { onPost("api/orders/restore", ["id": o.id]) }
            } else {
                if o.kind == "auto" && o.status != "done" {
                    // Колокольчик: пишет в чат при срабатывании или молчит.
                    let on = (o.notify ?? 1) != 0
                    actButton(on ? "bell" : "bell.slash", tint: on ? .naomiAccent : .naomiMuted) {
                        onPost("api/orders/update", ["id": o.id, "notify": on ? 0 : 1])
                    }
                }
                if (o.kind == "remind" || o.kind == "auto") && o.status != "done" {
                    actButton(o.status == "paused" ? "play" : "pause") {
                        onPost("api/orders/update", ["id": o.id, "status": o.status == "paused" ? "active" : "paused"])
                    }
                }
                if o.status == "done" {
                    // Вернуть в работу: стикер снова повиснет, дело — снова в «Сделать».
                    actButton("arrow.uturn.backward") { onPost("api/orders/reopen", ["id": o.id]) }
                }
                actButton("trash") { onPost("api/orders/trash", ["id": o.id]) }
            }
        }
    }

    private func actButton(_ icon: String, tint: Color = .naomiMuted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(nfont(13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let when = o.humanWhen, !when.isEmpty {
                Text(when + (o.humanDo != nil ? " → " + o.humanDo! : ""))
                    .font(nfont(13))
                    .foregroundStyle(Color.naomiSoft)
            }
            Text(statusLine)
                .font(nfont(12))
                .foregroundStyle(Color.naomiMuted.opacity(0.9))
        }
    }

    private var statusLine: String {
        var s = todo ? "сработало — отметь, когда сделаешь"
            : o.status == "active" ? "ждёт"
            : o.status == "paused" ? "на паузе"
            : o.status == "done" ? "выполнено" : "в корзине"
        if let n = o.fireCount, n > 0 {
            s += " · срабатывало \(n) раз"
            if let ts = o.lastFired { s += ", последний — " + fireStamp(ts) }
        }
        if o.kind == "auto" && (o.notify ?? 1) == 0 && o.status != "trash" { s += " · молча" }
        return s
    }
}

// ── Форма создания (напоминание с условием / простая заметка) ──

private struct OrderForm {
    var title = ""
    var trigger = "in"
    var minutes = 30
    var who = "Слава"
    var temp = 26
    var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    var when = Date().addingTimeInterval(3600)
    var repeatOn = false
    var act = ""            // действие правила (автоматика)
    var actTemp = 24        // …и °C для «охлаждение на …°»
    var notifyOn = true     // писать в чат при срабатывании

    // Форма → JSON-триггер движка (те же типы, что у инструментов Наоми — orderTrig в вебе).
    func buildTrig() -> [String: Any]? {
        switch trigger {
        case "in": return ["type": "at", "ts": Int(Date().timeIntervalSince1970) + minutes * 60]
        case "at": return ["type": "at", "ts": Int(when.timeIntervalSince1970)]
        case "daily":
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return ["type": "daily", "hh": c.hour ?? 9, "mm": c.minute ?? 0]
        case "come": return ["type": "come", "who": who]
        case "leave": return ["type": "leave", "who": who]
        case "nobody": return ["type": "presence_hold", "cond": "nobody_home", "sustain_sec": minutes * 60]
        case "somebody": return ["type": "presence_hold", "cond": "somebody_home", "sustain_sec": 0]
        case "temp_gt": return ["type": "metric", "source": "climate", "metric": "ambient_c", "op": ">", "value": temp]
        case "temp_lt": return ["type": "metric", "source": "climate", "metric": "ambient_c", "op": "<", "value": temp]
        case "vac_on": return ["type": "device", "source": "vacuum", "metric": "cleaning", "text": "on"]
        case "vac_off": return ["type": "device", "source": "vacuum", "metric": "cleaning", "text": "off"]
        case "ac_on": return ["type": "device", "source": "climate", "metric": "power", "text": "on"]
        case "ac_off": return ["type": "device", "source": "climate", "metric": "power", "text": "off"]
        case "tv_on": return ["type": "device", "source": "androidtv", "metric": "power", "text": "on"]
        case "tv_off": return ["type": "device", "source": "androidtv", "metric": "power", "text": "off"]
        default: return nil
        }
    }

    // Форма → JSON-действие правила (как orderAction в вебе).
    func buildAction() -> [String: Any]? {
        switch act {
        case "ac_off": return ["type": "ac", "patch": ["on": false]]
        case "ac_on": return ["type": "ac", "patch": ["on": true]]
        case "ac_cool": return ["type": "ac", "patch": ["on": true, "mode": "cool", "temp": actTemp]]
        case "vac_clean": return ["type": "vacuum", "cmd": "start_vacuum"]
        case "vac_mop": return ["type": "vacuum", "cmd": "start_mop"]
        case "vac_combo": return ["type": "vacuum", "cmd": "start_combo"]
        case "vac_dock": return ["type": "vacuum", "cmd": "dock"]
        case "tv_on": return ["type": "tv", "patch": ["on": true]]
        case "tv_off": return ["type": "tv", "patch": ["on": false]]
        default: return nil
        }
    }
}

private let orActions: [(v: String, label: String)] = [
    ("", "— действие —"),
    ("ac_off", "выключить кондиционер"),
    ("ac_on", "включить кондиционер (прошлый режим)"),
    ("ac_cool", "включить кондёр: охлаждение на …°"),
    ("vac_clean", "запустить пылесос (сухая)"),
    ("vac_mop", "запустить мойку полов"),
    ("vac_combo", "запустить уборку с мойкой"),
    ("vac_dock", "отправить пылесос на базу"),
    ("tv_on", "включить телевизор"),
    ("tv_off", "отправить телевизор в сон"),
]

private let orTriggers: [(v: String, label: String)] = [
    ("in", "через … минут"),
    ("at", "в точное время"),
    ("daily", "каждый день в …"),
    ("come", "когда придёт домой…"),
    ("leave", "когда уйдёт…"),
    ("nobody", "когда никого нет дома … минут"),
    ("somebody", "когда кто-то вернётся домой"),
    ("temp_gt", "температура в гостиной выше …°"),
    ("temp_lt", "температура в гостиной ниже …°"),
    ("vac_on", "пылесос начнёт уборку"),
    ("vac_off", "пылесос закончит уборку"),
    ("ac_on", "кондиционер включится"),
    ("ac_off", "кондиционер выключится"),
    ("tv_on", "телевизор включится"),
    ("tv_off", "телевизор выключится"),
]
private let orWho = ["Слава", "Настя", "любой"]

private struct OrderCreateForm: View {
    let scope: OrdersScope
    @Binding var form: OrderForm
    var onCreate: () -> Void
    var onCancel: () -> Void

    private var needMinutes: Bool { form.trigger == "in" || form.trigger == "nobody" }
    private var needWho: Bool { form.trigger == "come" || form.trigger == "leave" }
    private var needTemp: Bool { form.trigger == "temp_gt" || form.trigger == "temp_lt" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(scope == .notes ? "что не забыть: «отключить T-Mobile до конца месяца»"
                      : scope == .auto ? "суть правила: «выключать кондёр при уходе»"
                      : "о чём напомнить: «покормить котов»",
                      text: $form.title, axis: .vertical)
                .font(nfont(15.5))
                .lineLimit(2...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.naomiBg.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if scope == .reminds || scope == .auto {
                // Условие: меню + дополнительные поля под выбранный тип.
                HStack(spacing: 8) {
                    Picker("", selection: $form.trigger) {
                        ForEach(orTriggers, id: \.v) { t in
                            Text(t.label).tag(t.v)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.naomiSoft)
                    Spacer(minLength: 0)
                }

                if needMinutes || needWho || needTemp || form.trigger == "at" || form.trigger == "daily" {
                    HStack(spacing: 8) {
                        if needMinutes {
                            TextField("минут", value: $form.minutes, format: .number)
                                .keyboardType(.numberPad)
                                .frame(width: 64)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.naomiBg.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text("минут").font(nfont(14)).foregroundStyle(Color.naomiMuted)
                        }
                        if form.trigger == "at" {
                            DatePicker("", selection: $form.when)
                                .labelsHidden()
                        }
                        if form.trigger == "daily" {
                            DatePicker("", selection: $form.time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        if needWho {
                            Picker("", selection: $form.who) {
                                ForEach(orWho, id: \.self) { w in
                                    Text(w == "любой" ? "кто-нибудь" : w).tag(w)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Color.naomiSoft)
                        }
                        if needTemp {
                            TextField("°C", value: $form.temp, format: .number)
                                .keyboardType(.numberPad)
                                .frame(width: 56)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.naomiBg.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text("°C").font(nfont(14)).foregroundStyle(Color.naomiMuted)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if scope == .auto {
                    // Действие правила: что сделать руками, когда условие сложится.
                    HStack(spacing: 8) {
                        Picker("", selection: $form.act) {
                            ForEach(orActions, id: \.v) { a in
                                Text(a.label).tag(a.v)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.naomiSoft)
                        if form.act == "ac_cool" {
                            TextField("°C", value: $form.actTemp, format: .number)
                                .keyboardType(.numberPad)
                                .frame(width: 56)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.naomiBg.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text("°C").font(nfont(14)).foregroundStyle(Color.naomiMuted)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Toggle(isOn: $form.repeatOn) {
                    Text("постоянное (каждый раз)")
                        .font(nfont(14.5))
                        .foregroundStyle(Color.naomiSoft)
                }
                .tint(Color.naomiAccent)

                if scope == .auto {
                    Toggle(isOn: $form.notifyOn) {
                        Text("писать при срабатывании")
                            .font(nfont(14.5))
                            .foregroundStyle(Color.naomiSoft)
                    }
                    .tint(Color.naomiAccent)
                }
            }

            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .font(nfont(14.5))
                    .foregroundStyle(Color.naomiMuted)
                    .buttonStyle(.plain)
                Button(action: onCreate) {
                    Text("Создать")
                        .font(nfont(14.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.naomiAccent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.naomiBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// ── Помощники ──

// Раскладка текста карточки: нумерованные пункты и маркеры — на свою строку
// (тот же prettifyCard, что в вебе; идемпотентно, содержимое не меняется).
private func prettifyCard(_ text: String) -> String {
    var t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    t = t.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
    t = t.replacingOccurrences(of: "[ \\t]+(\\d{1,2}[).][ \\t])", with: "\n$1", options: .regularExpression)
    t = t.replacingOccurrences(of: "[ \\t]+([-•][ \\t])", with: "\n$1", options: .regularExpression)
    return t
}

private let orMonths = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]

// «6 июл в 20:15» — когда напоминание срабатывало в последний раз.
private func fireStamp(_ ts: Int) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(ts))
    let c = Calendar.current.dateComponents([.day, .month, .hour, .minute], from: d)
    return "\(c.day ?? 0) \(orMonths[(c.month ?? 1) - 1]) в " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

#Preview {
    OrdersView(scope: .reminds)
}
