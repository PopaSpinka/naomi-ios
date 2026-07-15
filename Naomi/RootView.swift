// Каркас приложения: выдвижная шторка навигации слева (как в приложении Claude)
// и стопка экранов-разделов. Чат — главный экран, остальные пока заготовки:
// наполнение приедет следующими этапами (умный дом, таймлайн, идеи...).
import SwiftUI

// Разделы приложения — те же вкладки, что в вебе.
enum NaomiSection: String, CaseIterable, Identifiable {
    case chat, home, timeline, ideas, notes, reminders, auto, files
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Чат"
        case .home: "Умный дом"
        case .timeline: "Таймлайн"
        case .ideas: "Идеи"
        case .notes: "Заметки"
        case .reminders: "Напоминалки"
        case .auto: "Автоматика"
        case .files: "Файлы"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .home: "house"
        case .timeline: "calendar.day.timeline.left"
        case .ideas: "lightbulb"
        case .notes: "note.text"
        case .reminders: "bell"
        case .auto: "gearshape.2"
        case .files: "folder"
        }
    }
}

struct RootView: View {
    @State private var section: NaomiSection = .chat
    @State private var menuOpen = false
    // Корзина Идей открывается поверх экрана своей кнопкой-стеклом справа
    // (в OrdersView). Пока она открыта — кнопка шторки слева становится «назад».
    @State private var ideasTrashOpen = false

    var body: some View {
        GeometryReader { geo in
            // Шторка не во весь экран: справа остаётся полоса текущего экрана —
            // видно, куда возвращаться, и тап по ней закрывает шторку.
            // Ширину крутить здесь: доля экрана и потолок в поинтах.
            let drawerWidth = min(geo.size.width * 0.66, 272)

            ZStack(alignment: .leading) {
                SideMenu(current: section, onSelect: select)
                    .frame(width: drawerWidth)
                    // Контейнер растянут на физический экран (ignoresSafeArea ниже),
                    // так что чёлку и подбородок шторка отступает сама.
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                    // Лёгкий параллакс: шторка доезжает последнюю треть пути
                    // вместе с экраном — глубина, как в приложении Claude.
                    .offset(x: menuOpen ? 0 : -drawerWidth * 0.3)

                screens
                    // Скругление и тень живут только у отъехавшего экрана:
                    // прижатый — обычный, во весь экран и без рамок.
                    .clipShape(RoundedRectangle(cornerRadius: menuOpen ? 34 : 0, style: .continuous))
                    // Тень — на ПОДЛОЖКЕ позади карточки, а не на самих экранах.
                    // .shadow поверх screens заставлял каждый кадр анимации шторки
                    // растеризовать все восемь экранов (стекло, текст) в скрытый буфер
                    // и размывать его целиком — отсюда просадка FPS при открытии шторки.
                    // Тень от простого залитого прямоугольника (та же форма и скругление)
                    // считается дёшево, а на глаз карточка выглядит ровно как раньше.
                    // Подложка — вплотную под клипнутой картой, из-под неё торчит только тень.
                    .background {
                        RoundedRectangle(cornerRadius: menuOpen ? 34 : 0, style: .continuous)
                            .fill(Color.naomiBg)
                            .shadow(color: .black.opacity(menuOpen ? 0.22 : 0), radius: 30, x: -10)
                    }
                    // Кнопка шторки — НЕ в тулбаре, а своя, парит поверх карточки.
                    // Системную кнопку в шапке при нажатии раздувало стеклом вверх
                    // и резало о потолок шапки (границу safe area) — свободную кнопку
                    // не режет никто. Стоит ПОСЛЕ тени (вне её растеризации) и ДО
                    // offset (едет вместе с карточкой при открытии шторки).
                    .overlay(alignment: .topLeading) {
                        // Рамка карточки — от физического верха экрана, чёлку
                        // отступаем сами (geo снаружи знает настоящие отступы).
                        // В корзине Идей та же кнопка — уже «назад» на главный экран.
                        let back = section == .ideas && ideasTrashOpen
                        GlassCircleButton(systemName: back ? "chevron.left" : "line.3.horizontal.decrease") {
                            // Возврат из корзины — мгновенно, без withAnimation: анимация
                            // смены list↔trash «схлопывала» текст карточек (см. OrdersView).
                            if back { ideasTrashOpen = false }
                            else { openMenu() }
                        }
                            .padding(.leading, 18)
                            .padding(.top, geo.safeAreaInsets.top + 4)
                    }
                    .overlay {
                        // Открытая шторка приглушает отъехавший экран: сверху ложится
                        // вуаль цвета фона — сам фон на вид не меняется, а текст,
                        // кнопки и иконки гаснут до ~40% тем же ходом, что и сдвиг.
                        // Лежит НАД кнопкой шторки (она тоже элемент — тоже гаснет)
                        // и ДО offset — едет вместе с карточкой.
                        RoundedRectangle(cornerRadius: menuOpen ? 34 : 0, style: .continuous)
                            .fill(Color.naomiBg)
                            .opacity(menuOpen ? 0.6 : 0)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        // Пока шторка открыта, экран за ней «заморожен»: тап по нему
                        // (включая кнопку) или свайп влево закрывает шторку. Ловец
                        // висит ДО offset — offset сдвигает картинку, но не рамку
                        // разметки, и ловец, навешанный после, накрыл бы весь экран
                        // вместе со шторкой.
                        if menuOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(perform: closeMenu)
                                .gesture(
                                    DragGesture(minimumDistance: 25)
                                        .onEnded { v in
                                            if v.translation.width < -40 { closeMenu() }
                                        }
                                )
                        }
                    }
                    .offset(x: menuOpen ? drawerWidth : 0)
            }
            // КЛЮЧЕВОЕ: рамка разметки экранов обязана быть с ФИЗИЧЕСКИЙ экран.
            // ignoresSafeArea на самих экранах НЕ помогает: он расширяет только
            // отрисовку, а рамку разметки — по ней режет clipShape и считается
            // тень — оставляет в границах safe area. Из-за этого приложение
            // стояло «письмом в конверте»: чёрные полосы сверху/снизу, порезанный
            // текст под часами и срезанные при нажатии стеклянные кнопки.
            // Расширение на КОНТЕЙНЕРЕ растит именно предложение разметки детям —
            // экраны получают полный экран рамкой. Только .container: клавиатурную
            // зону не трогаем, ввод как ездил за клавиатурой, так и ездит.
            .ignoresSafeArea(.container)
            // Внутри растянутого контейнера «родные» отступы safe area обнулены —
            // пробрасываем настоящий отступ чёлки экранам (нужен шестерёнке в чате).
            .environment(\.naomiTopInset, geo.safeAreaInsets.top)
        }
        .background(Color.naomiBg.ignoresSafeArea())
        // ГЛОБАЛЬНОГО жеста-свайпа тут больше нет — и не вешать: распознаватель
        // на весь экран участвует в каждом касании и отменяет нажатия кнопок,
        // стоит пальцу дрогнуть на пару точек (стекло мигает, действие не
        // срабатывает — «кликается с пятого раза»). Мышь в симуляторе не дрожит,
        // поэтому там такое не ловится. Свайп-закрытие живёт только на ловце
        // поверх сдвинутого экрана, где кнопок нет.
    }

    // Стопка экранов. ВСЕ экраны живут всегда и не пересоздаются при переключении:
    // данные подгружены заранее (задачи стартуют вместе с приложением), поэтому
    // выбранная в шторке вкладка открывается уже наполненной — без пустоты и
    // резкого появления контента посреди анимации. Прокрутка, стрим чата и
    // черновики переживают походы по разделам. Спрятанные экраны сбавляют опрос
    // сервера через active — часто поллит только видимый (см. каждую вьюху).
    // Кнопку шторки экраны не носят — она одна, парит поверх в RootView.
    private var screens: some View {
        ZStack {
            // Чат ВСЕГДА в стопке — его состояние (черновик, живой стрим, прокрутка)
            // переживает походы по вкладкам, и именно на нём живёт клавиатура.
            ChatView()
                .sectionVisible(section == .chat)
            // Прочие вкладки рисуем ТОЛЬКО когда открыты. Раньше все 8 экранов висели
            // в стопке всегда — и раскладка проходила по всем восьми на КАЖДЫЙ кадр
            // движения клавиатуры в чате: пустые (без сети) проходились мгновенно, а
            // набитые данными с сервера — по 8 глубоких деревьев за кадр, оттого 10 fps
            // при сворачивании (подтверждено замером: с одним чатом в стопке жест идеально
            // гладкий). Теперь рядом с чатом висит максимум один экран — открытый. Плата:
            // вкладка грузится при открытии (сеть локальная — доли секунды), а не заранее;
            // состояние чата это не трогает.
            switch section {
            case .chat:
                EmptyView()
            case .home:
                HomeView(active: true)
            case .timeline:
                TimelineView(active: true)
            case .ideas:
                OrdersView(scope: .ideas, trashOpen: $ideasTrashOpen, active: true)
            case .notes:
                OrdersView(scope: .notes, active: true)
            case .reminders:
                OrdersView(scope: .reminds, active: true)
            case .auto:
                OrdersView(scope: .auto, active: true)
            case .files:
                FilesView(active: true)
            }
        }
    }

    private func select(_ s: NaomiSection) {
        section = s
        ideasTrashOpen = false   // сменили раздел — корзина Идей закрыта
        closeMenu()
    }

    private func openMenu() {
        // Клавиатуру — вниз: шторка рядом с торчащей клавиатурой смотрится ломано.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.snappy(duration: 0.32)) { menuOpen = true }
    }

    private func closeMenu() {
        withAnimation(.snappy(duration: 0.32)) { menuOpen = false }
    }
}

// ── Шторка ──

// Логотип Naomi сверху (как серифный Claude у них) и список разделов.
// Текущий раздел подсвечен пилюлей — цветом пузыря, как выделение в Claude.
private struct SideMenu: View {
    let current: NaomiSection
    var onSelect: (NaomiSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Naomi")
                .font(.system(size: 30, weight: .medium, design: .serif))
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)

            ForEach(NaomiSection.allCases) { s in
                row(s)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ s: NaomiSection) -> some View {
        Button { onSelect(s) } label: {
            HStack(spacing: 14) {
                Image(systemName: s.icon)
                    .font(.title3)
                    .frame(width: 30)
                Text(s.title)
                    .font(.title3)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if s == current {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.naomiBubble)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

// Круглая стеклянная кнопка поверх шапки — шторка слева, шестерёнка справа
// (в ChatView). Не в тулбаре: системные кнопки шапки при нажатии раздуваются
// и режутся о её потолок. Стекло то же, что у системных; interactive — родной
// блик и продавливание. Стиль кнопки — обычный, как у рабочей кнопки отправки.
struct GlassCircleButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassCircleBackground()
        }
    }
}

private extension View {
    // Экран из стопки: виден и кликабелен только выбранный, остальные лежат
    // прозрачными — прозрачный слой GPU не рисует, а состояние и данные живут.
    func sectionVisible(_ on: Bool) -> some View {
        self.opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            // Спрятанные экраны НЕ отодвигаются от клавиатуры. Контейнер RootView
            // гасит только .container-зону (клавиатурную оставляет живой), поэтому
            // иначе клавиатурный отступ приходит ВСЕМ восьми экранам разом — и каждый
            // кадр движения клавиатуры (сворачивание пальцем, скрытие при открытии
            // шторки) все восемь пересчитывают разметку, хотя виден один. Это и есть
            // главный тормоз при сворачивании. Целим edges динамически, а НЕ через
            // if/else: тип вида не меняется — ChatView не пересоздаётся, стрим и
            // черновик переживают переключение вкладок. Пустой набор = обычное
            // поведение (видимый экран отъезжает от клавиатуры как раньше).
            .ignoresSafeArea(.keyboard, edges: on ? [] : .all)
    }

    // Родное «жидкое стекло» iOS 26, как у кнопок шапки; фолбэк — матовый круг.
    @ViewBuilder
    func glassCircleBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(Color.naomiBubble, in: Circle())
        }
    }
}

// Настоящий отступ чёлки для экранов внутри растянутого контейнера RootView:
// там «родной» safe area уже обнулён, а парящим кнопкам он нужен.
private struct TopSafeInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var naomiTopInset: CGFloat {
        get { self[TopSafeInsetKey.self] }
        set { self[TopSafeInsetKey.self] = newValue }
    }
}

#Preview {
    RootView()
}
