// Умный дом — панель как в вебе (frontend/app.jsx HomePanel): погода, гостиная,
// присутствие, телевизор, кондиционер, пылесос. Кнопки шлют команды на тот же
// POST /api/home; подсветка нажатого держится оптимистично, пока железо догоняет
// (ТВ будится по ADB несколько секунд, пылесос отвечает через сайдкар).
import SwiftUI

// Фон сегментов и кнопок — как #222220 у веба, в светлой теме — бумага-пузырь.
private let segBg = Color(light: 0xEFEAE0, dark: 0x222220)

private struct SegOption {
    let v: String
    let label: String
}

private let acModes = [SegOption(v: "cool", label: "охлаждение"), SegOption(v: "dry", label: "осушение"),
                       SegOption(v: "eco", label: "эко"), SegOption(v: "fan", label: "вентиляция")]
private let acFans = [SegOption(v: "auto", label: "авто"), SegOption(v: "low", label: "низ"),
                      SegOption(v: "middle", label: "сред"), SegOption(v: "high", label: "выс")]
// Режимы пылесоса — кнопки-команды: «начни уборку такого вида» / «на базу».
private let vacModes = [SegOption(v: "dock", label: "док"), SegOption(v: "пылесосит", label: "уборка"),
                        SegOption(v: "моет", label: "моет"), SegOption(v: "пылесосит и моет", label: "общая")]

struct HomeView: View {
    // Вкладка сейчас на экране? Экран живёт в стопке RootView всегда — скрытый
    // тоже обновляется, но редким тиком (данные тёплые к моменту переключения).
    var active = true

    @State private var home: NaomiAPI.HomeState?
    @State private var failed = false
    // Монотонная «эпоха» команд, как в вебе: клик повышает эпоху, и ответы поллов,
    // стартовавших до клика, выбрасываются — старый снимок не затирает оптимизм.
    @State private var epoch = 0
    // Оптимистичная подсветка: что нажали и до какого момента верим без подтверждения.
    @State private var vacPend: (v: String, deadline: Date)?
    @State private var tvPend: (on: Bool, deadline: Date)?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.naomiBg.ignoresSafeArea()
                content
            }
            .navigationTitle("Умный дом")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Открытая вкладка поллит бодро (веб ходит раз в секунду, телефону хватает
        // двух), спрятанная — раз в минуту, чтобы к переключению всё было готово.
        // Смена active перезапускает задачу — возврат на вкладку сразу обновляет.
        .task(id: active) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(active ? 2 : 60))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let h = home {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if failed {
                        waitText("сервер не отвечает — данные могли устареть", err: true)
                            .padding(.top, 10)
                    }
                    weatherSection(h.weather)
                    hairline
                    livingRoomSection(h.ac)
                    hairline
                    presenceSection(h.presence ?? [:])
                    hairline
                    tvSection(h.tv)
                    hairline
                    acSection(h.ac)
                    hairline
                    vacuumSection(h.vacuum)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        } else if failed {
            waitText("сервер не отвечает — данные могли устареть", err: true)
        } else {
            ProgressView().tint(Color.naomiMuted)
        }
    }

    // ── Секции (порядок и тексты — как в вебе) ──

    @ViewBuilder
    private func weatherSection(_ w: NaomiAPI.HomeState.Weather?) -> some View {
        section {
            if let w, w.ok == true {
                HStack(spacing: 14) {
                    Image(systemName: skySymbol(w.condition, isDay: w.isDay ?? true))
                        .font(nfont(30, weight: .light))
                        .opacity(0.9)
                    Text(w.feels != nil ? "\(w.feels!)°" : "—")
                        .font(nfont(34, weight: .light))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cap(w.condition) ?? "—")
                            .font(nfont(14.5))
                        Text(weatherSub(w))
                            .font(nfont(12.5))
                            .foregroundStyle(Color.naomiMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            } else if w?.stale == true {
                waitText("погода устарела — нет связи с Open-Meteo", err: true)
            } else {
                waitText("погода загружается…")
            }
        }
    }

    @ViewBuilder
    private func livingRoomSection(_ ac: NaomiAPI.HomeState.AC?) -> some View {
        section {
            if let ac, ac.online == true, let ambient = ac.ambient {
                row("Гостиная") {
                    HStack(spacing: 12) {
                        HStack(spacing: 5) {
                            Image(systemName: "thermometer.medium").foregroundStyle(Color.naomiMuted)
                            Text(ambientLabel(ambient) + "°")
                        }
                        if let air = cap(ac.air) {
                            HStack(spacing: 5) {
                                Image(systemName: "leaf").foregroundStyle(Color.naomiMuted)
                                Text(air)
                            }
                        }
                    }
                    .font(nfont(14))
                }
            } else {
                waitText("нет данных с датчиков")
            }
        }
    }

    @ViewBuilder
    private func presenceSection(_ presence: [String: NaomiAPI.HomeState.Person]) -> some View {
        section {
            if presence.isEmpty {
                waitText("датчик присутствия не на связи")
            } else {
                ForEach(presence.keys.sorted(), id: \.self) { name in
                    let isHome = presence[name]?.home == true
                    row(name) {
                        HomeSeg(value: isHome ? "y" : "n",
                                options: [SegOption(v: "n", label: "не дома"), SegOption(v: "y", label: "дома")],
                                ro: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tvSection(_ tv: NaomiAPI.HomeState.TV?) -> some View {
        section {
            if tv?.online == true {
                row("Телевизор") {
                    HomeSeg(value: tvShown ? "y" : "n",
                            options: [SegOption(v: "n", label: "выключен"), SegOption(v: "y", label: "включён")]) { v in
                        clickTv(v == "y")
                    }
                }
            } else {
                waitText("телевизор не на связи")
            }
        }
    }

    @ViewBuilder
    private func acSection(_ ac: NaomiAPI.HomeState.AC?) -> some View {
        let online = ac?.online == true
        let on = ac?.on == true
        section {
            secHeader("Кондиционер") {
                if online {
                    HomeSeg(value: on ? "y" : "n",
                            options: [SegOption(v: "y", label: "вкл"), SegOption(v: "n", label: "выкл")]) { v in
                        send(["ac": ["on": v == "y"]])
                    }
                }
            }
            if !online {
                waitText("кондиционер не на связи")
            } else {
                row("Температура") {
                    HomeStep(value: ac?.temp ?? 22, suffix: "°", range: 16...32, ro: !on) { v in
                        send(["ac": ["temp": v]])
                    }
                }
                row("Режим") {
                    HomeCycle(value: ac?.mode ?? "cool", options: acModes, ro: !on) { v in
                        send(["ac": ["mode": v]])
                    }
                }
                row("Вентилятор") {
                    HomeSeg(value: ac?.fan ?? "auto", options: acFans, ro: !on) { v in
                        send(["ac": ["fan": v]])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func vacuumSection(_ vac: NaomiAPI.HomeState.Vacuum?) -> some View {
        section {
            secHeader("Робот-пылесос") {
                if vac?.online == true, let bat = vac?.battery {
                    HStack(spacing: 4) {
                        if vac?.stateRu == "заряжается" {
                            Image(systemName: "bolt.fill").font(nfont(11))
                        }
                        Text("\(bat)%")
                    }
                    .font(nfont(14, weight: .semibold))
                    .monospacedDigit()
                }
            }
            if vac?.online == true {
                row("Статус") {
                    HomeSeg(value: vacShown, options: vacModes) { v in
                        clickVac(v)
                    }
                }
            } else {
                waitText("пылесос не на связи")
            }
        }
    }

    // ── Оптимистичная подсветка (как в вебе) ──

    private var vacActive: String {
        guard let v = home?.vacuum else { return "" }
        return v.cleanKind ?? (v.docked == true ? "dock" : "")
    }
    private var vacShown: String {
        if let p = vacPend, Date() < p.deadline { return p.v }
        return vacActive
    }
    private func clickVac(_ v: String) {
        guard v != vacShown else { return }
        vacPend = (v, Date().addingTimeInterval(12))    // роботу хватает, дальше верим статусу
        send(["vacuum": ["do": v]])
    }

    private var tvActual: Bool { home?.tv?.on == true }
    private var tvShown: Bool {
        if let p = tvPend, Date() < p.deadline { return p.on }
        return tvActual
    }
    private func clickTv(_ on: Bool) {
        guard on != tvShown else { return }
        tvPend = (on, Date().addingTimeInterval(25))    // пробуждение ТВ по ADB — несколько секунд
        send(["tv": ["on": on]])
    }

    // Статус догнал нажатое (или вышло время) — оптимизм больше не нужен.
    private func reconcilePending() {
        if let p = vacPend, p.v == vacActive || Date() >= p.deadline { vacPend = nil }
        if let p = tvPend, p.on == tvActual || Date() >= p.deadline { tvPend = nil }
    }

    // ── Сеть ──

    private func load() async {
        let my = epoch
        do {
            let fresh = try await NaomiAPI.home()
            guard my == epoch else { return }   // пока летел ответ, была команда — снимок устарел
            home = fresh
            failed = false
            reconcilePending()
        } catch {
            if !Task.isCancelled, my == epoch { failed = true }
        }
    }

    private func send(_ patch: [String: Any]) {
        epoch += 1
        let my = epoch
        Task {
            do {
                let fresh = try await NaomiAPI.patchHome(patch)
                guard my == epoch else { return }
                home = fresh
                failed = false
                reconcilePending()
            } catch {
                if my == epoch { failed = true }
            }
        }
    }

    // ── Кусочки разметки ──

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 1)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 15)
    }

    private func secHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .textCase(.uppercase)
                .font(nfont(11.5, weight: .bold))
                .kerning(0.9)
                .foregroundStyle(Color.naomiMuted)
            Spacer()
            trailing()
        }
        .frame(minHeight: 28)
        .padding(.bottom, 8)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(nfont(14.5))
                .foregroundStyle(Color.naomiSoft)
            Spacer(minLength: 10)
            content()
        }
        .padding(.vertical, 5)
    }

    private func waitText(_ s: String, err: Bool = false) -> some View {
        Text(s)
            .font(nfont(13.5))
            .foregroundStyle(err ? Color.naomiErr : Color.naomiMuted)
            .padding(.vertical, 2)
    }

    // ── Мелкие помощники ──

    private func cap(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func ambientLabel(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func weatherSub(_ w: NaomiAPI.HomeState.Weather) -> String {
        var s = "ветер " + (w.windMs != nil ? "\(Int(w.windMs!.rounded())) м/с" : "—")
        if let gust = w.gustMs, gust >= 6 { s += ", порывы \(Int(gust.rounded()))" }
        if let rain = w.rainProb { s += " · дождь \(rain)%" }
        if let uv = w.uvBand, !uv.isEmpty { s += " · UV " + uv }
        return s
    }

    // Иконка неба по русскому описанию — те же правила, что wxSkyIcon в вебе.
    private func skySymbol(_ condition: String?, isDay: Bool) -> String {
        let c = (condition ?? "").lowercased()
        if c.contains("гроз") { return "cloud.bolt.rain" }
        if c.contains("снег") || c.contains("метел") || c.contains("вьюг") { return "cloud.snow" }
        if c.contains("дожд") || c.contains("ливен") || c.contains("морос") { return "cloud.rain" }
        if c.contains("туман") || c.contains("дымк") || c.contains("мгла") { return "cloud.fog" }
        if c.contains("облач") || c.contains("пасмур") { return "cloud" }
        return isDay ? "sun.max" : "moon"
    }
}

// ── Управляющие элементы — как home-seg / home-step / home-cycle в вебе ──

// Сегменты: контейнер-пилюля, активный залит. ro — только показывает (присутствие,
// выключенный кондиционер), нажатия не принимает.
private struct HomeSeg: View {
    let value: String
    let options: [SegOption]
    var ro = false
    var onPick: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.v) { o in
                Button {
                    if !ro && o.v != value { onPick(o.v) }
                } label: {
                    Text(o.label)
                        .font(nfont(13))
                        .foregroundStyle(o.v == value ? Color.primary : Color.naomiMuted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background {
                            if o.v == value {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(segBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .allowsHitTesting(!ro)
    }
}

// Шаговый регулятор −/значение/+ (температура кондиционера).
private struct HomeStep: View {
    let value: Int
    var suffix = ""
    let range: ClosedRange<Int>
    var ro = false
    var onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            stepButton("minus") { onSet(max(range.lowerBound, value - 1)) }
            Text("\(value)\(suffix)")
                .font(nfont(14.5, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 52)
            stepButton("plus") { onSet(min(range.upperBound, value + 1)) }
        }
        .opacity(ro ? 0.45 : 1)
        .allowsHitTesting(!ro)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(nfont(13, weight: .medium))
                .frame(width: 32, height: 32)
                .background(segBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// Кнопка-карусель: клик листает режимы по кругу (режим кондиционера).
private struct HomeCycle: View {
    let value: String
    let options: [SegOption]
    var ro = false
    var onPick: (String) -> Void

    var body: some View {
        let i = max(0, options.firstIndex(where: { $0.v == value }) ?? 0)
        let label = options[i].label
        Button {
            onPick(options[(i + 1) % options.count].v)
        } label: {
            Text(label)
                .font(nfont(13))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(segBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .opacity(ro ? 0.55 : 1)
        .allowsHitTesting(!ro)
    }
}

#Preview {
    HomeView()
}
