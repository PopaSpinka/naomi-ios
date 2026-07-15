// Таймлайн дома — лента переходов, один в один с вебом (frontend/app.jsx
// TimelinePanel): дни липкими шапками, слева время, рельса с цветной точкой
// по модулю, жирная часть + деталь, серые метаданные с чипом «кто сделал».
// Пока вкладка открыта — поллим сервер, как веб (свежие переходы сами приедут).
import SwiftUI

// Цвет точки по модулю — словарь из веба (TL_COLORS): с ходу отличать
// присутствие/кондёр/микроклимат/пылесос. Неизвестный модуль — серый.
private let tlDotColors: [String: Color] = [
    "Присутствие": Color(light: 0x4A9EFF, dark: 0x4A9EFF),
    "Кондиционер": Color(light: 0xF2994A, dark: 0xF2994A),
    "Микроклимат": Color(light: 0x56CCA0, dark: 0x56CCA0),
    "Пылесос": Color(light: 0xB28DD6, dark: 0xB28DD6),
    "Напоминание": Color(light: 0xE0B341, dark: 0xE0B341),
    "Автоматика": Color(light: 0x4DB6AC, dark: 0x4DB6AC),
    "Телевизор": Color(light: 0x7E87FF, dark: 0x7E87FF),
]
private let tlGray = Color(light: 0x8B877F, dark: 0x8B877F)
// Приглушённый текст (время, метаданные, шапки дней) — как #8b877f в вебе,
// в светлой теме чуть темнее ради читаемости на бумаге.
private let tlMuted = Color(light: 0x7D786D, dark: 0x8B877F)

private let tlMonths = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]

// Ширина колонки времени растёт вместе с масштабом (nfont) — с жёсткими 42
// «00:16» на ×1.2 переносилось на две строки, Слава поймал на телефоне.
private let tlTimeWidth: CGFloat = 42 * naomiSectionScale

// День ленты: события уже приходят новые-сверху — режем на дни в том же порядке.
private struct TLDay: Identifiable {
    let id: String
    let label: String
    var items: [TLItem]
}

private struct TLItem: Identifiable {
    let id: String
    let ev: NaomiAPI.TimelineEvent
}

struct TimelineView: View {
    // Вкладка сейчас на экране? Экран живёт в стопке RootView всегда — скрытый
    // тоже обновляется, но редким тиком (лента тёплая к моменту переключения).
    var active = true

    @State private var events: [NaomiAPI.TimelineEvent] = []
    @State private var loaded = false   // первый ответ пришёл (пустая лента ≠ «грузим»)
    @State private var failed = false   // ошибка ≠ «пока пусто»: не врём про пустую ленту
    // Рисуем не всю ленту разом, а первые shownCount событий (самые свежие сверху);
    // старое приезжает порциями при прокрутке вниз. События уже в памяти — подгрузка
    // мгновенная. Так и разметка дешевле, и группировка по дням считается по окну.
    @State private var shownCount = TimelineView.windowBase
    private static let windowBase = 80    // сколько свежих событий показываем сразу
    private static let windowStep = 80    // сколько добавляем за одну подгрузку вниз

    var body: some View {
        NavigationStack {
            ZStack {
                Color.naomiBg.ignoresSafeArea()
                content
            }
            .navigationTitle("Таймлайн")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Открытая вкладка поллит как веб (4 сек), спрятанная — раз в минуту:
        // к переключению лента уже наполнена. Смена active перезапускает задачу.
        .task(id: active) {
            // Спрятанная вкладка прогревается ОДИН раз и затихает — фоновый опрос раз в
            // минуту пересобирал вьюху на главном потоке и спотыкал жест клавиатуры в чате
            // (подробно — в HomeView). Живой опрос только у открытой; прогрев — если данных
            // ещё нет, чтобы уход с вкладки не тянул лишний запрос.
            guard active else {
                if !loaded {
                    try? await Task.sleep(for: .milliseconds(700))
                    await load()
                }
                return
            }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
            if !loaded {
                ProgressView().tint(tlMuted)
            } else {
                Text(failed ? "сервер не отвечает — лента не обновляется" : "пока пусто — данные копятся…")
                    .font(nfont(13.5))
                    .foregroundStyle(tlMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        } else {
            ScrollView {
                if failed {
                    Text("сервер не отвечает — лента не обновляется")
                        .font(nfont(12.5))
                        .foregroundStyle(tlMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { idx, item in
                                row(item.ev, isLastInDay: idx == day.items.count - 1)
                            }
                        } header: {
                            dayHeader(day.label)
                        }
                    }
                    // Порог подгрузки: как только этот ряд доезжает до низа (LazyVStack
                    // рождает его только тогда), показываем следующую порцию старого.
                    // Старое приходит СНИЗУ — лента не прыгает, доскролл не нужен.
                    if shownCount < events.count {
                        ProgressView()
                            .tint(tlMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .onAppear { shownCount = min(shownCount + Self.windowStep, events.count) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            // Потянул обновить — снова показываем только свежую верхушку.
            .refreshable { shownCount = Self.windowBase; await load() }
        }
    }

    // ── Кусочки ленты ──

    private func dayHeader(_ label: String) -> some View {
        Text(label)
            .textCase(.uppercase)
            .font(nfont(11.5, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(tlMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            // Шапка липкая — непрозрачный фон, чтобы лента не просвечивала под ней.
            .background(Color.naomiBg)
    }

    private func row(_ ev: NaomiAPI.TimelineEvent, isLastInDay: Bool) -> some View {
        let color = tlDotColors[ev.module ?? ""] ?? tlGray
        return HStack(alignment: .top, spacing: 9) {
            Text(clock(ev.ts))
                .font(nfont(13))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(tlMuted)
                .frame(width: tlTimeWidth, alignment: .leading)

            // Точка с ореолом — по центру первой строки текста.
            Circle()
                .fill(color.opacity(0.16))
                .frame(width: 14, height: 14)
                .overlay(Circle().fill(color).frame(width: 8, height: 8))
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                what(ev)
                    .font(nfont(15))
                    .foregroundStyle(.primary)
                meta(ev)
            }
            .padding(.bottom, 2)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        // Рельса: непрерывная линия за точками (точка рисуется поверх).
        // У последнего события дня линии нет — дни разделены, как в вебе.
        .background(alignment: .leading) {
            if !isLastInDay {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 2)
                    // Центр точки: колонка времени + зазор 9 + 14/2; линия 2pt — минус 1.
                    .padding(.leading, tlTimeWidth + 15)
            }
        }
    }

    // «Слава — пришёл домой»: жирная часть + разделитель + деталь одной строкой.
    private func what(_ ev: NaomiAPI.TimelineEvent) -> Text {
        let label = ev.label ?? ""
        let detail = ev.detail ?? ""
        guard !detail.isEmpty else { return Text(label).fontWeight(.semibold) }
        return Text(label).fontWeight(.semibold) + Text(" \(ev.sep ?? "—") \(detail)")
    }

    // «Присутствие · [Автоматика] · 17 минут» — модуль, чип «кто», длительность.
    private func meta(_ ev: NaomiAPI.TimelineEvent) -> some View {
        HStack(spacing: 4) {
            Text(ev.module ?? "Событие")
            if let who = ev.source, !who.isEmpty {
                Text("·")
                Text(who)
                    .font(nfont(11.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            if let dur = ev.durLabel, !dur.isEmpty {
                Text("· " + dur)
            }
        }
        .font(nfont(12.5))
        .foregroundStyle(tlMuted)
        .lineLimit(1)
    }

    // ── Данные ──

    private var days: [TLDay] {
        let cal = Calendar.current
        var out: [TLDay] = []
        var curKey = ""
        for ev in events.prefix(shownCount) {
            let date = Date(timeIntervalSince1970: TimeInterval(ev.ts))
            let c = cal.dateComponents([.year, .month, .day], from: date)
            let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
            if key != curKey {
                out.append(TLDay(id: key, label: dayLabel(date, cal: cal), items: []))
                curKey = key
            }
            out[out.count - 1].items.append(TLItem(id: "\(key)-\(out[out.count - 1].items.count)", ev: ev))
        }
        return out
    }

    private func dayLabel(_ date: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let d = cal.component(.day, from: date)
        let m = cal.component(.month, from: date)
        return "\(d) \(tlMonths[m - 1])"
    }

    private func clock(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func load() async {
        do {
            events = try await NaomiAPI.timeline()
            failed = false
        } catch {
            // Отмену (ушли с вкладки посреди запроса) за ошибку сети не считаем.
            if !Task.isCancelled { failed = true }
        }
        loaded = true
    }
}

#Preview {
    TimelineView()
}
