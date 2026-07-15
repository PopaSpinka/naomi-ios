// Экран чата — как веб-вкладка, один в один: лента пузырей сверху, поле ввода снизу.
import SwiftUI
import PhotosUI

// Фото, выбранное к отправке: миниатюра на руках сразу, загрузка на склад — в фоне.
struct PendingAttachment: Identifiable {
    let id = UUID()
    var thumb: UIImage?
    var uploaded: NaomiAPI.UploadedAttachment?   // nil — ещё едет на сервер
    var failed = false                           // не доехало: ⚠️ на миниатюре, убрать крестиком
}

// Коробка под отложенные прокрутки. Живёт в @State ради постоянства, но менять её
// поля можно без перерисовки экрана (ссылка на класс не меняется) — задачам прокрутки
// незачем инвалидировать ленту. См. комментарий у scrollTasks в ChatView.
private final class ScrollTaskBox {
    var keyboard: Task<Void, Never>?
    var barGrow: Task<Void, Never>?
    var older: Task<Void, Never>?   // возврат якоря после подгрузки старых сообщений
    var lastKbH: CGFloat = 0         // прошлая высота клавиатуры — чтобы ловить ТОЛЬКО подъём
}

// Хвост ленты (маркер-«дно») — общий id для колонки пузырей и обработчиков прокрутки.
private let chatTailID = "chat-tail"

// Колонка пузырей вынесена в ОТДЕЛЬНЫЙ Equatable-вид: пока сами сообщения не изменились,
// SwiftUI её пропускает (== вернёт true) и НЕ пересобирает 80 пузырей. Раньше лента жила
// прямо в body экрана и перетряхивалась на каждый чих прокрутки (isNearBottom и т.п.) —
// это и есть тот главный поток, что «поддёргивал» и скролл, и сворачивание клавиатуры.
// Биндинг lightbox и замыкание onRetry в сравнении не участвуют (их и не с чем сверять),
// но пишут в стабильное хранилище — работают даже когда вид пропущен.
private struct BubbleColumn: View, Equatable {
    let messages: ArraySlice<ChatMessage>
    let loadError: String?
    @Binding var lightbox: LightboxItem?
    var onRetry: () -> Void

    static func == (a: BubbleColumn, b: BubbleColumn) -> Bool {
        a.loadError == b.loadError && a.messages.elementsEqual(b.messages)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let loadError {
                errorCard(loadError)
            }
            ForEach(messages) { msg in
                MessageBubble(message: msg, onTapImage: { lightbox = LightboxItem(rel: $0) })
                    // Воздух вокруг запроса Славы: зазор «запрос ↔ ответ» 12 → 16
                    // (+30%, просьба 15.07); слои ответа между собой остаются на 12.
                    .padding(.vertical, msg.role == .user ? 4 : 0)
                    .id(msg.id)
            }
            Color.clear
                .frame(height: 14)
                .id(chatTailID)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Попробовать ещё раз", action: onRetry)
                .font(.subheadline.weight(.medium))
                .tint(.naomiAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// Кэш разметки: маркдаун (жирный/курсив) парсится один раз на строку и запоминается.
// У готовых сообщений текст не меняется, а тело пузыря пересобирается часто (набор
// текста в поле, прокрутка) — без кэша это лишний парсинг одного и того же на каждый
// проход разметки. Только для застывшего текста; живой стрим рисует FadeInText сам.
@MainActor
private enum MarkdownCache {
    private static var store: [String: AttributedString] = [:]

    static func attributed(_ s: String) -> AttributedString {
        if let hit = store[s] { return hit }
        let parsed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        if store.count > 500 { store.removeAll(keepingCapacity: true) }   // грубая крышка от роста
        store[s] = parsed
        return parsed
    }
}

struct ChatView: View {
    // Настоящий отступ чёлки от RootView: контейнер экранов растянут на весь
    // дисплей, «родные» отступы safe area внутри обнулены (см. RootView).
    @Environment(\.naomiTopInset) private var topInset
    // Холодный старт — сразу со слепком с телефона: чат виден мгновенно,
    // сеть догоняет в фоне (loadHistory) и тихо обновляет, если что-то изменилось.
    @State private var messages: [ChatMessage] = ChatCache.load()
    @State private var input = ""
    @State private var sending = false
    @State private var loadError: String?
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    // Отложенные прокрутки (под клавиатуру и под рост поля) держим в классе-коробке,
    // а НЕ в @State: переустановка задачи не должна перерисовывать экран. Раньше они
    // жили в @State — и каждое событие клавиатуры/поля дёргало пересборку всей ленты
    // (до 300 пузырей). Ровно это и проседало, когда клавиатуру свайпом ведёшь вниз.
    // iOS шлёт событие клавиатуры 2–3 раза подряд — прежнюю задачу отменяем, чтобы
    // движение осталось ровно одно.
    @State private var scrollTasks = ScrollTaskBox()
    // Пользователь у дна ленты? Если он листает старую переписку, клавиатура
    // не должна утаскивать чат вниз — вниз прокрутит только отправка сообщения.
    @State private var isNearBottom = true
    // Листал ли пользователь ленту рукой с тех пор, как она была на дне. Датчик
    // «у дна» на холодном старте даёт ложное «нет» из-за ленивой разметки, поэтому
    // блокируем клавиатурный подъезд только по СОЧЕТАНИЮ: далеко от дна И листал сам.
    @State private var scrolledAwayByHand = false
    // Высота поля ввода: когда оно растёт (перенос строки), лента едет вверх,
    // чтобы последний пузырь не накрывало.
    @State private var barHeight: CGFloat = 0
    // Прокрутка под рост поля — та же схема и та же коробка, что у клавиатуры
    // (scrollTasks выше): новая высота применяется к ленте на следующем проходе
    // разметки, мгновенный scrollTo целился по старым размерам и не двигал чат.
    // Вложения: выбор из фотоплёнки, очередь к отправке, открытое на весь экран фото.
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pendingAtts: [PendingAttachment] = []
    @State private var lightbox: LightboxItem?
    // Заставка на холодном старте: прячет, как чат встаёт на место (уловка Claude).
    @State private var showSplash = true
    // Лента рисует не всю историю разом, а последние windowCount сообщений. Остальное
    // лежит в messages и подтягивается окном при прокрутке вверх (данные уже в памяти —
    // подгрузка мгновенная, без похода в сеть). 300 живых пузырей разом — вот что
    // проседало: на экране нужны 1–2 экрана переписки, а не вся история сразу.
    @State private var windowCount = ChatView.windowBase

    var body: some View {
        ZStack {
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
                .sheet(isPresented: $showSettings) {
                    SettingsSheet { Task { await loadHistory() } }
                }
                .fullScreenCover(item: $lightbox) { item in
                    LightboxView(rel: item.rel)
                }
            }
            // Шестерёнка — парит поверх шапки, не в тулбаре: системную кнопку
            // при нажатии раздувало стеклом и резало о потолок шапки (та же
            // болячка, что была у кнопки шторки — см. RootView). Отступ чёлки —
            // вручную из naomiTopInset, вровень с кнопкой шторки слева.
            .overlay(alignment: .topTrailing) {
                GlassCircleButton(systemName: "gearshape") { showSettings = true }
                    .padding(.trailing, 18)
                    .padding(.top, topInset + 4)
            }

            // Заставка холодного старта (уловка Claude): пока под ней чат встаёт на
            // место, наверху — спокойная надпись; тает — а всё уже готово. Клавиатура
            // (она в системном слое выше приложения) выезжает поверх с родной анимацией.
            if showSplash {
                splash
                    .zIndex(1)
            }
        }
        .task {
            // «Визитку» держит только системный launch screen. Наша копия заставки
            // лишь бесшовно перехватывает его на первом кадре и сразу тает,
            // одновременно выезжает клавиатура. Микро-пауза — на первую разметку
            // чата за заставкой, глазу она не видна.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                withAnimation(.easeOut(duration: 0.60)) { showSplash = false }
                inputFocused = true
            }
            await loadHistory()
        }
    }

    // Экран-заставка: чистый тёплый фон, без надписи — бесшовно продолжает
    // системный launch screen (он такого же цвета) и тает над готовым интерфейсом.
    private var splash: some View {
        Color.naomiBg
            .ignoresSafeArea()
            .transition(.opacity)
    }

    // ── Лента ──

    // Хвост ленты: прокрутка кодом целится в него, а пружина клампит контент по нему же —
    // поэтому «дно» всегда одно и то же, и последний пузырь не заезжает в зону затемнения
    // у поля ввода. Зазор «пузырь — поле» = высота хвоста + spacing стека.
    // Показываем сразу windowBase последних сообщений; выше — по windowStep за подгрузку.
    // База небольшая (60): колонка НЕ ленивая (Lazy промахивался офсетом при смене высоты
    // клавиатуры — чат «исчезал»), поэтому все пузыри окна пересчитывают разметку, когда
    // клавиатуру ведёшь пальцем вниз. Меньше окно — легче этот покадровый пересчёт. Шаг
    // подгрузки крупный (80): первый же долист вверх поднимает окно до 140, так что
    // подгрузка (единственный момент, где лента может дёрнуть) при листании истории редка.
    private static let windowBase = 60
    private static let windowStep = 80

    // Последние windowCount сообщений — то, что реально рисуется. suffix сам берёт
    // всё, если история короче окна. Живой ответ всегда последний, значит всегда в окне.
    private var windowed: ArraySlice<ChatMessage> { messages.suffix(windowCount) }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Обычный VStack (внутри BubbleColumn), не Lazy: ленивая разметка при смене
                // высоты клавиатуры/поля промахивалась офсетом в нерассчитанную зону — чат
                // «исчезал». Рисуется только окно windowed (старое приезжает прокруткой
                // вверх), а сама колонка — Equatable-вид: прокрутка её НЕ пересобирает.
                BubbleColumn(messages: windowed, loadError: loadError, lightbox: $lightbox,
                             onRetry: { Task { await loadHistory() } })
                    .equatable()
            }
            .scrollDismissesKeyboard(.interactively)
            .bottomAnchoredStart()
            .trackNearBottom($isNearBottom, handScrolled: $scrolledAwayByHand)
            // Подтягиваем старые сообщения, когда прокрутка почти у верха окна.
            .trackNearTop { growOlder(proxy) }
            .onChange(of: messages.last?.text) {
                // Растущий ответ мягко подталкивает ленту вверх (телепорт строки
                // лечится именно анимацией). Если Слава ушёл листать старое — не трогаем.
                guard isNearBottom || !scrolledAwayByHand else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(chatTailID, anchor: .bottom)
                }
            }
            .onChange(of: barHeight) { oldH, newH in
                // Поле ввода подросло (перенос строки) — двигаем ленту следом,
                // чтобы последний пузырь не уехал под поле. Уменьшение не трогаем:
                // при сжатии поля контент и так остаётся видимым.
                guard oldH > 0, newH > oldH, !messages.isEmpty,
                      isNearBottom || !scrolledAwayByHand else { return }
                scrollTasks.barGrow?.cancel()
                scrollTasks.barGrow = Task { @MainActor in
                    // Кадр на то, чтобы лента узнала о новой высоте поля, иначе
                    // прокрутка целится по старым размерам и остаётся на месте.
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                    // Тихая добивка: если первый заход попал точно — пустой ход.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages.count) { oldCount, _ in
                guard !messages.isEmpty else { return }
                if oldCount == 0 {
                    // Первичная загрузка истории: встаём на дно мгновенно, без «киносеанса»
                    // с прокруткой всей переписки. Тихая добивка — после ленивой разметки,
                    // чтобы дно было точным и клавиатурный подъезд не блокировался.
                    proxy.scrollTo(chatTailID, anchor: .bottom)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                } else {
                    // Отправка или новый ответ — единственный момент, когда чат едет вниз
                    // из любой глубины переписки.
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(chatTailID, anchor: .bottom)
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
                // Реагируем ТОЛЬКО на подъём клавиатуры. На сворачивании пальцем клавиатура
                // едет вниз вместе с рукой — гнать в этот момент ленту к дну значило бы
                // драться с пальцем (то самое «поддёргивание при сворачивании»). Прошлую
                // высоту помним в коробке (не в @State — незачем перерисовывать ленту).
                let prevKbH = scrollTasks.lastKbH
                scrollTasks.lastKbH = max(kbH, 0)
                guard isNearBottom || !scrolledAwayByHand, kbH > 0, !messages.isEmpty else { return }
                guard kbH >= prevKbH else { return }   // вниз (сворачивание) — не вмешиваемся
                scrollTasks.keyboard?.cancel()
                scrollTasks.keyboard = Task { @MainActor in
                    // Первый скролл — почти сразу, чтобы ехать ПАРАЛЛЕЛЬНО с клавиатурой
                    // (одно движение на глаз). Даже после холодного старта, когда система
                    // не считает ленту «докрученной» и сама её не везёт.
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                    // Тихая добивка после всех анимаций: если первый скролл попал точно —
                    // это пустой ход, если промахнулся на пиксели — мягко доводит.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                }
            }
        }
    }

    // Прокрутка почти у верха окна — показываем следующую порцию старых сообщений.
    // Данные уже в memory (messages), так что подгрузка мгновенная. Чтобы добавленные
    // сверху ряды не столкнули ленту вниз, тут же возвращаем якорь — самое старое из
    // ранее показанных — на верх экрана: смотришь ту же переписку, старое лежит выше,
    // готовое к дальнейшей прокрутке. scrolledAwayByHand в условии отсекает ложный
    // «верх» на первом кадре холодного старта (пока Слава не листнул рукой).
    private func growOlder(_ proxy: ScrollViewProxy) {
        guard windowCount < messages.count, scrolledAwayByHand else { return }
        let anchorID = windowed.first?.id
        windowCount = min(windowCount + Self.windowStep, messages.count)
        guard let anchorID else { return }
        scrollTasks.older?.cancel()
        scrollTasks.older = Task { @MainActor in
            // Кадр на то, чтобы новые ряды встали в разметку, иначе якорь целится
            // по старым позициям. Без анимации — подмена происходит незаметно.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    // ── Поле ввода ──

    private var inputBar: some View {
        VStack(spacing: 8) {
            // Очередь фото к отправке: миниатюры с крестиком, пока едут — спиннер.
            if !pendingAtts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAtts) { att in
                            pendingThumb(att)
                        }
                    }
                    .padding(.top, 6)   // воздух под крестики
                    .padding(.horizontal, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                // «+» — добавить фото из плёнки. 42 = высота поля в одну строку
                // (строка ~22 + отступы 10+10) — кнопка и поле стоят вровень.
                PhotosPicker(selection: $pickedItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 42, height: 42)
                        .sendGlassBackground()
                }
                .onChange(of: pickedItems) { _, items in
                    guard !items.isEmpty else { return }
                    pickedItems = []
                    for item in items {
                        Task { await addAttachment(item) }
                    }
                }

                textFieldWithSend
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)       // зазор «пузырь — поле» даёт хвост ленты (14 + spacing 12 = 26)
        .padding(.bottom, 16)   // воздух между полем и клавиатурой — как в iMessage
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }

    // Поле ввода с кнопкой отправки внутри пузыря.
    private var textFieldWithSend: some View {
        TextField("Напиши Наоми…", text: $input, axis: .vertical)
            .lineLimit(1...5)
            .focused($inputFocused)
            .padding(.leading, 14)
            .padding(.trailing, 46)   // место под кнопку внутри пузыря
            .padding(.vertical, 10)
            .inputGlassBackground()
            // Кнопка отправки внутри пузыря, справа. Пока отправлять нечего — её нет;
            // с первым символом или выбранным фото мягко вырастает из ничего.
            // При одной строке стоит по центру, при росте поля прижимается к низу.
            .overlay(alignment: .bottomTrailing) {
                if hasDraft {
                    sendButton(size: 32, font: .subheadline)
                        .padding(5)   // (42 − 32) / 2 — вровень с полем в одну строку
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: hasDraft)
    }

    // Черновик не пуст: есть текст или фото — есть что отправлять.
    private var hasDraft: Bool { !input.isEmpty || !pendingAtts.isEmpty }

    // Миниатюра фото в очереди: пока едет на склад — полупрозрачная со спиннером.
    private func pendingThumb(_ att: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let t = att.thumb {
                    Image(uiImage: t).resizable().scaledToFill()
                } else {
                    Color.naomiBubble
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(att.uploaded == nil ? 0.55 : 1)
            .overlay {
                if att.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                } else if att.uploaded == nil {
                    ProgressView()
                }
            }

            Button {
                pendingAtts.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .offset(x: 6, y: -6)
        }
    }

    // Выбранное в плёнке фото: миниатюра сразу в очередь, загрузка на склад — фоном.
    private func addAttachment(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let filename = "IMG_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
        let thumb = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 400, height: 400))
        let pending = PendingAttachment(thumb: thumb)
        pendingAtts.append(pending)
        do {
            let up = try await NaomiAPI.upload(data: data, filename: filename)
            guard let i = pendingAtts.firstIndex(where: { $0.id == pending.id }) else { return }
            pendingAtts[i].uploaded = up
            // Семя кэша миниатюр: фото уже на руках, из сети не перетягивать.
            if let thumb { RemoteImage.seed(rel: up.name, image: thumb) }
        } catch {
            // Не доехало до склада: миниатюра остаётся с ⚠️ (убрать — крестиком),
            // отправка заблокирована, причина — в консоли Xcode.
            print("Наоми: загрузка фото не удалась:", error)
            if let i = pendingAtts.firstIndex(where: { $0.id == pending.id }) {
                pendingAtts[i].failed = true
            }
        }
    }

    private var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let uploading = pendingAtts.contains { $0.uploaded == nil }
        return !sending && !uploading && (hasText || !pendingAtts.isEmpty)
    }

    // Кнопка отправки: стеклянный круг со стрелкой. Одна и та же в двух местах
    // (рядом с полем и внутри пузыря), отличается только размером.
    private func sendButton(size: CGFloat, font: Font) -> some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(font.weight(.bold))
                .foregroundStyle(canSend ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .sendGlassBackground()
        }
        .disabled(!canSend)
    }

    // ── Работа с сервером ──

    private func loadHistory() async {
        do {
            let fresh = Array(try await NaomiAPI.history().suffix(ChatCache.limit))
            loadError = nil
            ChatCache.save(fresh)
            // Живой ход не трогаем: подмена ленты посреди стрима снесла бы растущий
            // пузырь. Слепок на диске уже свежий — на следующем старте подхватится.
            guard !sending else { return }
            // Сеть совпала со слепком с телефона — не дёргаем ленту (и прокрутку) зря.
            if !sameConversation(fresh, messages) {
                messages = fresh
            }
        } catch {
            // Слепок уже на экране — молча остаёмся на нём; про сеть скажет отправка.
            if messages.isEmpty {
                loadError = "Не дозвонилась до Наоми.\nПроверь, что Мак не спит и телефон в домашнем Wi-Fi."
            }
        }
    }

    private func sameConversation(_ a: [ChatMessage], _ b: [ChatMessage]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.role == $1.role && $0.kind == $1.kind && $0.text == $1.text && $0.files == $1.files
        }
    }

    // Ход Наоми рисуется слоями, как в вебе: живая плашка «что делаю» отдельным
    // сообщением (название инструмента плавно меняется в одной строчке), затем
    // финальный текст. Кадр break режет текст на отдельные пузыри-слои (мозг начал
    // новый блок после дела или фоновой паузы) — куски не клеятся в один.
    // Плашка застывает галочкой. Ни индикатора «печатает», ни заготовки под ответ —
    // Слава убрал осознанно: ряды рождаются лениво, под реально пришедший контент.
    // Всё работает по id, а не по индексам. Текст выводится
    // пейсинг-буфером: мозг отдаёт кусочки рвано (то буква, то три слова), сырой
    // поток копится, а на экран стекает ЦЕЛЫМИ СЛОВАМИ в ровном ритме — небольшое
    // отставание от живого стрима, зато рваность спрятана полностью.
    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = pendingAtts.compactMap { $0.uploaded }
        guard canSend, !text.isEmpty || !atts.isEmpty else { return }
        input = ""
        pendingAtts = []
        sending = true
        var userMsg = ChatMessage(role: .user, text: text)
        userMsg.files = atts.map(\.name)
        messages.append(userMsg)

        var chipID: UUID? = nil      // активная плашка дела
        var replyID: UUID? = nil     // растущий текстовый пузырь
        var received = ""            // получено с сервера
        var shown = 0                // показано на экране (в символах)
        var streamDone = false

        // Место под ответ НЕ резервируем (15.07, Слава: «не готовь место заранее»):
        // отправленное сообщение просто встаёт последним, лента подъезжает к нему — и всё.
        // Ряд ответа рождается ЛЕНИВО, ровно когда виден контент: печатная машинка создаёт
        // его в момент показа ПЕРВОГО СЛОВА (не на первой дельте — иначе пустой ряд успел бы
        // сдвинуть ленту до текста), а тул — своей плашкой сразу с подписью. Так сдвиг ленты
        // всегда совпадает с появлением текста/плашки, без пустого мига между ними.

        func index(_ id: UUID?) -> Int? { id.flatMap { needle in messages.firstIndex { $0.id == needle } } }

        // Пейсинг: показываем по слову за тик, пауза между словами мягко сжимается,
        // когда буфер копится (отстаём — ускоряемся), и растягивается на маленьком
        // отставании. Неполное слово в хвосте буфера не показываем — ждём его буквы.
        let typewriter = Task { @MainActor in
            // Прайминг (однократно, в начале хода): не стартуем с пары букв («две буквы и
            // замерло») — сначала копим небольшой запас. Ждём НЕВИДИМО: ряд ответа ещё не
            // создан, лента не дёргается пустой заготовкой.
            while !streamDone && received.count < 12 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
            }
            while !Task.isCancelled {
                let chars = Array(received)
                let safe = wordSafeLimit(chars, done: streamDone)
                if shown < safe {
                    shown = nextWordEnd(chars, from: shown, limit: safe)
                    if let i = index(replyID) {
                        messages[i].text = String(chars.prefix(shown))
                    } else {
                        // Ряд текущего текст-блока ещё не рождён — создаём ЕГО СЕЙЧАС, уже с
                        // первым словом: сдвиг ленты и появление текста совпадают (ровно как
                        // у плашки тула), без пустого мига между ними.
                        if let c = index(chipID) { messages[c].isLive = false }   // дело → галочка
                        chipID = nil
                        var reply = ChatMessage(role: .assistant, text: String(chars.prefix(shown)), kind: .text)
                        reply.isStreaming = true
                        messages.append(reply)
                        replyID = reply.id
                    }
                    let backlog = chars.count - shown
                    var pause = backlog > 240 ? 26 : backlog > 120 ? 46 : backlog > 40 ? 68 : 92
                    if streamDone { pause = min(pause, 40) }   // стрим кончился — хвост доливаем бодрее
                    try? await Task.sleep(for: .milliseconds(pause))
                    continue
                }
                if streamDone && shown >= received.count { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        // Текст-слой закончился (кадр break, дело или файл после текста): пузырь застывает,
        // недопоказанный пейсингом хвост доливаем целиком; пустой ряд (букв не пришло)
        // убираем без следа. Буфер пейсинга — заново под следующий слой: иначе машинка
        // ждала бы «недопоказанные» буквы уже закрытого пузыря и ход не завершался.
        func closeReply() {
            if let r = index(replyID) {
                if received.isEmpty && messages[r].files.isEmpty {
                    messages.remove(at: r)
                } else {
                    messages[r].text = received
                    messages[r].isStreaming = false
                }
            } else if !received.isEmpty {
                // Блок закрылся, пока машинка ещё праймила (видимый ряд не успел родиться),
                // но текст пришёл — кладём его сразу застывшим, чтобы короткий блок не потерялся.
                if let c = index(chipID) { messages[c].isLive = false }
                chipID = nil
                messages.append(ChatMessage(role: .assistant, text: received))
            }
            replyID = nil
            received = ""; shown = 0
        }

        // Файл от Наоми — своим слоем на своём месте потока (как в вебе): текст до него
        // застывает, живая плашка дела — галочкой, следующий текст откроет новый пузырь.
        func showFile(_ rel: String) {
            closeReply()
            if let c = index(chipID) { messages[c].isLive = false }
            chipID = nil
            var m = ChatMessage(role: .assistant, text: "")
            m.files = [rel]
            messages.append(m)
        }

        func showAction(_ label: String) {
            closeReply()
            if let c = index(chipID) {
                withAnimation(.easeInOut(duration: 0.2)) { messages[c].text = label }   // та же плашка перетекает
            } else {
                var chip = ChatMessage(role: .assistant, text: label, kind: .action)
                chip.isLive = true
                messages.append(chip)
                chipID = chip.id
            }
        }

        func fail(_ text: String) {
            if let c = index(chipID) { messages[c].isLive = false }
            chipID = nil
            closeReply()   // что успело прийти — остаётся на экране целиком
            var e = ChatMessage(role: .assistant, text: text)
            e.isError = true
            messages.append(e)
        }

        Task { @MainActor in
            do {
                for try await event in NaomiAPI.send(text, attachments: atts) {
                    switch event {
                    case .delta(let piece):
                        // Ряд ответа НЕ создаём здесь — его родит печатная машинка в момент,
                        // когда покажет первое слово (сдвиг ленты совпадёт с появлением текста).
                        // Ведущий разделитель «\n\n» нового слоя гасим (после break сервер
                        // шлёт его первой дельтой — для клиентов, клеящих всё в одну строку).
                        received += received.isEmpty ? String(piece.drop(while: { $0.isNewline })) : piece
                    case .action(let label):
                        showAction(label)
                    case .textBreak:
                        closeReply()   // мозг начал новый текст-блок — следующая дельта откроет новый пузырь
                    case .file(let rel):
                        showFile(rel)
                    case .silent:
                        break   // сделала молча — застывшая плашка скажет сама
                    case .failure:
                        fail("Что-то пошло не так. Попробуй ещё раз.")
                    }
                }
                streamDone = true
                if let c = index(chipID) { messages[c].isLive = false }
            } catch {
                streamDone = true
                fail("Не дозвонилась до Наоми. Проверь Wi-Fi и что Мак не спит.")
            }
            await typewriter.value        // дать словам дотечь
            if let r = index(replyID) {
                if received.isEmpty && messages[r].files.isEmpty {
                    messages.remove(at: r)   // тихий ход — пустой ряд исчезает без следа
                } else if received.isEmpty {
                    messages[r].isStreaming = false   // только фото, без букв — ряд застывает
                } else {
                    messages[r].text = received
                    // Ждём, пока волна последнего слова доиграет (0.35 с), и застываем.
                    // БЕЗ withAnimation: подмена живого вида на статичный текст даёт
                    // одинаковую картинку, а анимация подмены «моргала» всем ответом.
                    try? await Task.sleep(for: .milliseconds(400))
                    if let r2 = index(replyID) { messages[r2].isStreaming = false }
                }
            }
            sending = false
            ChatCache.save(messages)   // ход закончен — слепок на телефоне свежий
        }
    }
}

// ── Пейсинг стрима: границы слов ──

// До какого места буфер можно показывать: неполное слово в хвосте ждёт свои буквы
// (кусочки с сервера режут слова где попало — «по пол слова» на экране не будет).
// Стрим закончился — можно всё.
private func wordSafeLimit(_ chars: [Character], done: Bool) -> Int {
    if done { return chars.count }
    var i = chars.count - 1
    var tail = 0
    while i >= 0, !chars[i].isWhitespace { i -= 1; tail += 1 }
    // «слово» тянется без пробелов неприлично долго (ссылка и т.п.) — не ждём его конца
    return tail > 60 ? chars.count : i + 1
}

// Конец следующего слова после позиции from (вместе с пробелами перед ним).
private func nextWordEnd(_ chars: [Character], from: Int, limit: Int) -> Int {
    var i = from
    while i < limit, chars[i].isWhitespace { i += 1 }
    while i < limit, !chars[i].isWhitespace { i += 1 }
    return max(i, min(from + 1, limit))
}

// Поле ввода как системный нижний бар (iOS 26): safeAreaBar даёт под ним родное
// прогрессивное размытие края — ровно то же, что система рисует под шапкой.
// На старых iOS — обычная вставка без эффекта.
private extension View {
    // Фон поля ввода: родное «жидкое стекло» iOS 26 — ровно тот же эффект,
    // что у системных кнопок в шапке (шестерёнки), поле не выделяется из
    // общего стиля. На старых iOS — прежний матовый пузырь.
    @ViewBuilder
    func inputGlassBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        } else {
            self.background(Color.naomiBubble, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    // Кнопка отправки — то же стекло, круглая; interactive даёт родной отклик
    // на нажатие (блик и продавливание, как у системных стеклянных кнопок).
    @ViewBuilder
    func sendGlassBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(Color.naomiBubble, in: Circle())
        }
    }

    // Старт ленты с низа. На iOS 18+ системный якорь ограничен ПЕРВИЧНОЙ разметкой:
    // рост контента ведём сами анимированной прокруткой — иначе якорь дёргает ленту
    // мгновенно, мимо анимации (тот самый телепорт строки при стриме).
    @ViewBuilder
    func bottomAnchoredStart() -> some View {
        if #available(iOS 18.0, *) {
            self.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }

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

    // Прокрутка почти у верха окна — сигналим наверх, что пора показать порцию старых
    // сообщений. Порог маленький (60 пт): данные уже в памяти, подгрузка мгновенная,
    // поэтому большой запас не нужен, а маленький — меньше сдвигает ленту при возврате
    // якоря. onScrollGeometryChange зовёт action только на СМЕНЕ значения, так что на
    // первом кадре (лента у дна) ложно не срабатывает. Старые iOS — без подгрузки.
    @ViewBuilder
    func trackNearTop(_ onReach: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y < 60
            } action: { _, isNear in
                if isNear { onReach() }
            }
        } else {
            self
        }
    }
}

// ── Пузырь сообщения ──

struct MessageBubble: View {
    let message: ChatMessage
    var onTapImage: (String) -> Void = { _ in }

    var body: some View {
        switch message.kind {
        case .action:   actionChip
        case .thinking: thinkingBubble
        case .text:     textBubble
        }
    }

    // «Думаю» — три пульсирующие точки; без пузыря, как и весь текст Наоми.
    private var thinkingBubble: some View {
        HStack {
            TypingDots()
                .padding(.vertical, 10)
            Spacer(minLength: 48)
        }
    }

    // Плашка «что Наоми делает»: голый приглушённый текст, без пузыря и иконок (act-layer
    // из веба). Пока дело живое — по тексту зациклено ходит светлая волна («фонарик»,
    // как у Claude/ChatGPT); застыло — тот же текст, только чуть тише.
    private var actionChip: some View {
        HStack {
            if message.isLive {
                ShimmerText(text: message.text)
            } else {
                Text(message.text)
                    .font(.system(size: naomiChipFontSize))
                    .foregroundStyle(.secondary)
                    .opacity(0.75)   // завершённый шаг тише активного (act-done из веба)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 48)
        }
    }

    // Вид как в приложении Claude: вопрос — нейтральный пузырь справа,
    // ответ Наоми — голый текст во всю ширину, без пузыря.
    @ViewBuilder
    private var textBubble: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    // Фото — голыми миниатюрами над пузырём текста (как в мессенджерах).
                    if !message.files.isEmpty {
                        MsgAttachments(files: message.files, onTapImage: onTapImage)
                    }
                    if !message.text.isEmpty {
                        Text(markdownText)
                            .font(.system(size: naomiChatFontSize))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.naomiBubble, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        } else {
            // Текст от края до края: слева — где раньше была граница пузыря,
            // справа — зеркально, без резерва под «хвост» чужих пузырей.
            VStack(alignment: .leading, spacing: 6) {
                if !message.files.isEmpty {
                    MsgAttachments(files: message.files, onTapImage: onTapImage)
                }
                if message.isStreaming || !message.text.isEmpty {
                    Group {
                        if message.isStreaming && message.text.isEmpty {
                            // Невидимая «буква» держит высоту ряда ровно как у первой
                            // строки будущего текста (тот же шрифт, те же отступы) —
                            // текст рождается на готовом месте, лента не прыгает.
                            Text(" ").hidden()
                        } else if #available(iOS 18.0, *), message.isStreaming {
                            FadeInText(text: message.text)   // слова проявляются волной
                        } else {
                            Text(markdownText)
                        }
                    }
                    .font(.system(size: naomiChatFontSize))
                    .foregroundStyle(Color.primary)
                    .opacity(message.isError ? 0.7 : 1)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Лёгкий маркдаун (жирный, курсив), с сохранением переносов строк. Парсинг
    // кэшируется (MarkdownCache): у готовых сообщений текст стабильный, а пузырь
    // пересобирается часто — незачем парсить одно и то же заново на каждый проход.
    private var markdownText: AttributedString {
        MarkdownCache.attributed(message.text)
    }
}

// ── Проявление слов в живом стриме (iOS 18+) ──
// Новые буквы рождаются прозрачными и мягко наливаются цветом волной —
// как в приложении Claude. Рисуем текст сами, по глифам, через TextRenderer.

@available(iOS 18.0, *)
private struct FadeInText: View {
    let text: String
    // Сколько глифов уже полностью видно; анимируется — волна ползёт по новым буквам.
    // Индикаторам тут не место (грабли: покадровая перерисовка рендерера сбрасывает
    // animatableData) — текст не перерисовывается покадрово, и волна работает без конфликтов.
    @State private var visible: Double = 0

    var body: some View {
        Text(Self.markdown(text))
            .textRenderer(WordFadeRenderer(visible: visible))
            .onAppear {
                // Вид рождается уже с первым словом (до этого ряд стоял пустым) —
                // проявляем это слово с нуля, той же волной.
                visible = 0
                withAnimation(.easeOut(duration: 0.35)) { visible = Double(text.count) }
            }
            .onChange(of: text) {
                withAnimation(.easeOut(duration: 0.35)) { visible = Double(text.count) }
            }
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

@available(iOS 18.0, *)
private struct WordFadeRenderer: TextRenderer {
    var visible: Double
    var animatableData: Double {
        get { visible }
        set { visible = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                // Целиком видимые куски рисуем одним вызовом — дёшево.
                if index + Double(run.count) <= visible {
                    ctx.draw(run)
                    index += Double(run.count)
                    continue
                }
                for glyph in run {
                    let over = index - visible
                    if over <= 0 {
                        ctx.draw(glyph)
                    } else {
                        let alpha = max(0.0, 1.0 - over / 10.0)   // хвост волны ~10 букв
                        if alpha > 0 {
                            var g = ctx
                            g.opacity = alpha
                            g.draw(glyph)
                        }
                    }
                    index += 1
                }
            }
        }
    }
}

// Живая подпись дела: по приглушённому тексту слева направо зациклено проходит
// светлая полоса — «фонарик», сигнал «Наоми делает это прямо сейчас в фоне».
// Аналог sp-shimmer из веба (styles.css), тот же период 2.2 с. Волна — градиентная
// полоса поверх текста, обрезанная маской по глифам; TimelineView двигает её покадрово
// (withAnimation тут не годится: repeatForever не пересчитал бы ход при смене подписи,
// а contentTransition-морф текста живёт своей жизнью под волной).
private struct ShimmerText: View {
    let text: String
    private static let period: Double = 2.2   // полный проход волны, как shimmer-slide в вебе

    var body: some View {
        label
            .overlay {
                // SwiftUI. — обязательно: TimelineView без префикса это наш экран таймлайна дома
                SwiftUI.TimelineView(.animation) { context in
                    GeometryReader { geo in
                        let phase = (context.date.timeIntervalSinceReferenceDate / Self.period)
                            .truncatingRemainder(dividingBy: 1)
                        let band = max(geo.size.width * 0.45, 36)   // ширина «луча»; короткой подписи — минимум
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.85), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band) * phase)
                    }
                }
                .mask(label)
                .allowsHitTesting(false)
            }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: naomiChipFontSize))
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
    }
}

// Три точки «Наоми думает»: бегущая волна прозрачности.
struct TypingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == i ? 1 : 0.3)
                    .scaleEffect(phase == i ? 1 : 0.7)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.easeInOut(duration: 0.28)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

#Preview {
    ChatView()
}
