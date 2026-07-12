// Экран чата — как веб-вкладка, один в один: лента пузырей сверху, поле ввода снизу.
import SwiftUI

struct ChatView: View {
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var loadError: String?
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    // Одна отложенная прокрутка под клавиатуру: iOS шлёт событие клавиатуры 2–3 раза
    // подряд, и без отмены предыдущей задачи чат дёргался двумя движениями.
    @State private var keyboardScroll: Task<Void, Never>?
    // Пользователь у дна ленты? Если он листает старую переписку, клавиатура
    // не должна утаскивать чат вниз — вниз прокрутит только отправка сообщения.
    @State private var isNearBottom = true
    // Листал ли пользователь ленту рукой с тех пор, как она была на дне. Датчик
    // «у дна» на холодном старте даёт ложное «нет» из-за ленивой разметки, поэтому
    // блокируем клавиатурный подъезд только по СОЧЕТАНИЮ: далеко от дна И листал сам.
    @State private var scrolledAwayByHand = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Фон на весь экран, включая зону за клавиатурой — чтобы при её появлении
                // за скруглёнными углами просвечивал интерфейс, а не чёрный провал (как в iMessage).
                Color.naomiBg.ignoresSafeArea()
                messagesList
            }
            // Поле ввода не отрезает ленту, а плавает над ней как системный бар: сообщения
            // проезжают под него и под клавиатуру, а система рисует под баром тот же
            // эффект «в размытие и затемнение», что и под шапкой (iOS 26).
            .floatingInputBar { inputBar }
            .navigationTitle("Наоми")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(.naomiAccent)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet { Task { await loadHistory() } }
            }
        }
        .task { await loadHistory() }
    }

    // ── Лента ──

    // Хвост ленты: прокрутка кодом целится в него, а пружина клампит контент по нему же —
    // поэтому «дно» всегда одно и то же, и последний пузырь не заезжает в зону затемнения
    // у поля ввода. Зазор «пузырь — поле» = высота хвоста + spacing стека.
    private static let tailID = "chat-tail"

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let loadError {
                        errorCard(loadError)
                    }
                    ForEach(messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    Color.clear
                        .frame(height: 6)
                        .id(Self.tailID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .trackNearBottom($isNearBottom, handScrolled: $scrolledAwayByHand)
            .onChange(of: messages.last?.text) {
                proxy.scrollTo(Self.tailID, anchor: .bottom)
            }
            .onChange(of: messages.count) { oldCount, _ in
                guard !messages.isEmpty else { return }
                if oldCount == 0 {
                    // Первичная загрузка истории: встаём на дно мгновенно, без «киносеанса»
                    // с прокруткой всей переписки. Тихая добивка — после ленивой разметки,
                    // чтобы дно было точным и клавиатурный подъезд не блокировался.
                    proxy.scrollTo(Self.tailID, anchor: .bottom)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(Self.tailID, anchor: .bottom)
                    }
                } else {
                    // Отправка или новый ответ — единственный момент, когда чат едет вниз
                    // из любой глубины переписки.
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.tailID, anchor: .bottom)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                // Бар сам поднимает «дно» ленты вместе с клавиатурой — остаётся довести
                // прокрутку до последнего сообщения. Событие приходит 2–3 раза подряд,
                // поэтому предыдущую задачу отменяем: движение остаётся ровно одно.
                // Если пользователь листает старую переписку (не у дна) — не трогаем:
                // он хочет видеть найденное место, а не дно чата.
                let kbH = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)
                    .map { UIScreen.main.bounds.height - $0.origin.y } ?? -1
                guard isNearBottom || !scrolledAwayByHand, kbH > 0, !messages.isEmpty else { return }
                keyboardScroll?.cancel()
                keyboardScroll = Task { @MainActor in
                    // Первый скролл — почти сразу, чтобы ехать ПАРАЛЛЕЛЬНО с клавиатурой
                    // (одно движение на глаз). Даже после холодного старта, когда система
                    // не считает ленту «докрученной» и сама её не везёт.
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.tailID, anchor: .bottom)
                    }
                    // Тихая добивка после всех анимаций: если первый скролл попал точно —
                    // это пустой ход, если промахнулся на пиксели — мягко доводит.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.tailID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Попробовать ещё раз") {
                Task { await loadHistory() }
            }
            .font(.subheadline.weight(.medium))
            .tint(.naomiAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // ── Поле ввода ──

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Напиши Наоми…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.naomiBubble, in: RoundedRectangle(cornerRadius: 22))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Color.naomiAccent : Color.naomiAccent.opacity(0.35))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)       // зазор «пузырь — поле» даёт хвост ленты (6 + spacing 10 = 16, как снизу)
        .padding(.bottom, 16)   // воздух между полем и клавиатурой — как в iMessage
    }

    private var canSend: Bool {
        !sending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ── Работа с сервером ──

    private func loadHistory() async {
        do {
            messages = try await NaomiAPI.history()
            loadError = nil
        } catch {
            loadError = "Не дозвонилась до Наоми.\nПроверь, что Мак не спит и телефон в домашнем Wi-Fi."
        }
    }

    // Ход Наоми рисуется слоями, как в вебе: живая плашка «что делаю» отдельным
    // сообщением (название инструмента плавно меняется в одной строчке), затем
    // финальный текст — своим пузырём. Плашка застывает галочкой, «думаю» без дел
    // исчезает бесследно.
    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        input = ""
        sending = true
        messages.append(ChatMessage(role: .user, text: text))

        var status = ChatMessage(role: .assistant, text: "думаю…", kind: .action)
        status.isLive = true
        messages.append(status)
        var statusIndex: Int? = messages.count - 1
        var sawAction = false      // плашка показывала настоящий инструмент, не «думаю»
        var replyIndex: Int? = nil // текущий текстовый пузырь этого хода

        // Плашка отработала: с настоящим делом — застывает галочкой, пустое «думаю» — исчезает.
        func freezeStatus() {
            guard let i = statusIndex else { return }
            if sawAction {
                messages[i].isLive = false
            } else {
                messages.remove(at: i)
                if let r = replyIndex, r > i { replyIndex = r - 1 }
            }
            statusIndex = nil
        }

        func appendReply(_ text: String, error: Bool = false) {
            freezeStatus()
            var reply = ChatMessage(role: .assistant, text: text)
            reply.isStreaming = !error
            reply.isError = error
            messages.append(reply)
            replyIndex = messages.count - 1
        }

        Task {
            do {
                for try await event in NaomiAPI.send(text) {
                    switch event {
                    case .delta(let piece):
                        if replyIndex == nil { appendReply("") }
                        if let r = replyIndex { messages[r].text += piece }
                    case .action(let name):
                        if let i = statusIndex {
                            // та же строчка плавно меняет название дела
                            sawAction = true
                            withAnimation(.easeInOut(duration: 0.2)) { messages[i].text = name }
                        } else {
                            // новый слой действий после текста — новая плашка
                            if let r = replyIndex { messages[r].isStreaming = false }
                            replyIndex = nil
                            var next = ChatMessage(role: .assistant, text: name, kind: .action)
                            next.isLive = true
                            messages.append(next)
                            statusIndex = messages.count - 1
                            sawAction = true
                        }
                    case .silent:
                        break   // сделала молча — застывшая плашка скажет сама
                    case .failure:
                        appendReply("Что-то пошло не так. Попробуй ещё раз.", error: true)
                    }
                }
                freezeStatus()
            } catch {
                appendReply("Не дозвонилась до Наоми. Проверь Wi-Fi и что Мак не спит.", error: true)
            }
            if let r = replyIndex { messages[r].isStreaming = false }
            sending = false
        }
    }
}

// Поле ввода как системный нижний бар (iOS 26): safeAreaBar даёт под ним родное
// прогрессивное размытие края — ровно то же, что система рисует под шапкой.
// На старых iOS — обычная вставка без эффекта.
private extension View {
    @ViewBuilder
    func floatingInputBar<Bar: View>(@ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            self
                .safeAreaBar(edge: .bottom, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }

    // Следим, у дна ли прокрутка (запас ~150 пт) и листал ли пользователь рукой.
    // Возврат на дно (любым способом) сбрасывает «листал»; жест пальцем — взводит.
    // На старых iOS ничего не отслеживаем — поведение просто остаётся прежним.
    @ViewBuilder
    func trackNearBottom(_ flag: Binding<Bool>, handScrolled: Binding<Bool>) -> some View {
        if #available(iOS 18.0, *) {
            self
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.visibleRect.maxY >= geo.contentSize.height - 150
                } action: { _, isNear in
                    flag.wrappedValue = isNear
                    if isNear { handScrolled.wrappedValue = false }
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .tracking || newPhase == .interacting {
                        handScrolled.wrappedValue = true
                    }
                }
        } else {
            self
        }
    }
}

// ── Пузырь сообщения ──

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.kind == .action {
            actionChip
        } else {
            textBubble
        }
    }

    // Плашка «что Наоми делает»: спиннер пока живая, галочка — когда дело сделано.
    private var actionChip: some View {
        HStack {
            HStack(spacing: 7) {
                if message.isLive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.naomiBubble.opacity(0.55), in: Capsule())
            Spacer(minLength: 48)
        }
    }

    private var textBubble: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Group {
                if message.text.isEmpty && message.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else {
                    Text(markdownText)
                        .font(.body)
                        .foregroundStyle(message.role == .user ? .white : Color.primary)
                        .opacity(message.isError ? 0.7 : 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user ? Color.naomiAccent : Color.naomiBubble,
                in: RoundedRectangle(cornerRadius: 18)
            )
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    // Лёгкий маркдаун (жирный, курсив), с сохранением переносов строк.
    private var markdownText: AttributedString {
        (try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.text)
    }
}

#Preview {
    ChatView()
}
