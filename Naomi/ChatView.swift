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
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                // Нижнего отступа у ленты нет намеренно: весь зазор «последний пузырь —
                // поле» живёт в верхнем отступе бара, поэтому он одинаков и когда скролл
                // останавливается сам, и когда прокручиваем кодом (scrollTo прижимает
                // пузырь ровно к краю ленты).
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .trackNearBottom($isNearBottom, handScrolled: $scrolledAwayByHand)
            .onChange(of: messages.last?.text) {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: messages.count) { oldCount, _ in
                guard let last = messages.last else { return }
                if oldCount == 0 {
                    // Первичная загрузка истории: встаём на дно мгновенно, без «киносеанса»
                    // с прокруткой всей переписки. Тихая добивка — после ленивой разметки,
                    // чтобы дно было точным и клавиатурный подъезд не блокировался.
                    proxy.scrollTo(last.id, anchor: .bottom)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                } else {
                    // Отправка или новый ответ — единственный момент, когда чат едет вниз
                    // из любой глубины переписки.
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
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
                guard isNearBottom || !scrolledAwayByHand, kbH > 0, let last = messages.last else { return }
                keyboardScroll?.cancel()
                keyboardScroll = Task { @MainActor in
                    // Первый скролл — почти сразу, чтобы ехать ПАРАЛЛЕЛЬНО с клавиатурой
                    // (одно движение на глаз). Даже после холодного старта, когда система
                    // не считает ленту «докрученной» и сама её не везёт.
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    // Тихая добивка после всех анимаций: если первый скролл попал точно —
                    // это пустой ход, если промахнулся на пиксели — мягко доводит.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
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
        .padding(.top, 16)      // зазор «последний пузырь — поле»: ровно такой же, как снизу
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

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        input = ""
        sending = true
        messages.append(ChatMessage(role: .user, text: text))
        var reply = ChatMessage(role: .assistant, text: "")
        reply.isStreaming = true
        messages.append(reply)
        let replyIndex = messages.count - 1

        Task {
            do {
                for try await event in NaomiAPI.send(text) {
                    switch event {
                    case .delta(let piece):
                        messages[replyIndex].text += piece
                    case .action(let name):
                        messages[replyIndex].actions.append(name)
                    case .silent:
                        break   // сделала молча — ниже покажем галочку
                    case .failure:
                        messages[replyIndex].isError = true
                        messages[replyIndex].text = "Что-то пошло не так. Попробуй ещё раз."
                    }
                }
                if messages[replyIndex].text.isEmpty && !messages[replyIndex].isError {
                    messages[replyIndex].text = "✓"   // молчаливое действие — как в вебе, без слов
                }
            } catch {
                messages[replyIndex].isError = true
                messages[replyIndex].text = "Не дозвонилась до Наоми. Проверь Wi-Fi и что Мак не спит."
            }
            messages[replyIndex].isStreaming = false
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
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.actions.enumerated()), id: \.offset) { _, action in
                    Label(action, systemImage: "gearshape.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if message.text.isEmpty && message.isStreaming {
                    TypingDots()
                } else if !message.text.isEmpty {
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

// Три точки «Наоми печатает…»
struct TypingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .padding(.vertical, 4)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                phase = (phase + 1) % 3
            }
        }
    }
}

#Preview {
    ChatView()
}
