// Файлы — склад и корзина, как вкладка в вебе (frontend/app.jsx FilesPanel):
// карточки с миниатюрой и описью из картотеки, поиск и фильтры-чипы, мягкая
// корзина. Удаление уводит файл в корзину (Наоми его «забывает»), восстановление
// возвращает вместе с карточкой; очистка корзины — единственное необратимое
// действие, поэтому с подтверждением.
import SwiftUI

private let flMonths = ["января", "февраля", "марта", "апреля", "мая", "июня",
                        "июля", "августа", "сентября", "октября", "ноября", "декабря"]
private let flChannels = ["web": "веб", "telegram": "телеграм", "inbox": "рабочий стол"]

// Что открыто в лайтбоксе: фото склада или корзины (у корзины другой маршрут).
private struct FLLightbox: Identifiable {
    let rel: String
    let trash: Bool
    var id: String { rel }
}

struct FilesView: View {
    // Вкладка сейчас на экране? Экран живёт в стопке RootView всегда: склад
    // загружается заранее при старте, а каждое открытие вкладки тихо обновляет
    // список — постоянного опроса файлам не нужно, они меняются редко.
    var active = true

    private enum Tab { case files, trash }

    @State private var tab: Tab = .files
    @State private var files: [NaomiAPI.FileEntry]?    // nil = ещё грузится
    @State private var trash: [NaomiAPI.FileEntry] = []
    @State private var failed = false
    @State private var busyRel: String?                 // файл, над которым идёт действие
    @State private var query = ""
    @State private var typeFilter: String?              // photo | doc
    @State private var channelFilter: String?           // web | telegram | inbox
    @State private var annotating: Set<String> = []     // отданы на опись — ждём карточку
    @State private var confirmEmpty = false
    @State private var lightbox: FLLightbox?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.naomiBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    tabsBar
                    filtersBar
                    list
                }
            }
            .navigationTitle("Файлы")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Первая загрузка — сразу при старте приложения (экран в стопке с рождения);
        // дальше тихое обновление при каждом открытии вкладки. Уход с вкладки
        // (active стал false) загрузку не дёргает — список уже на руках.
        .task(id: active) {
            // Скрытая на старте вкладка ждёт, пока чат встанет на место (см. HomeView).
            if !active { try? await Task.sleep(for: .milliseconds(700)) }
            if active || files == nil { await load() }
        }
        // Пока идёт опись — мягко поллим, чтобы карточки появились сами (как веб).
        .task(id: annotating.isEmpty) {
            guard !annotating.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await load()
            }
        }
        .fullScreenCover(item: $lightbox) { lb in
            LightboxView(rel: lb.rel, trash: lb.trash)
        }
        .alert("Очистить корзину насовсем?", isPresented: $confirmEmpty) {
            Button("Удалить всё", role: .destructive) { emptyAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это необратимо: файлы и их карточки пропадут навсегда.")
        }
    }

    // ── Шапка: Склад / Корзина + «Удалить всё» ──

    private var tabsBar: some View {
        HStack(spacing: 8) {
            tabChip("Склад" + ((files?.count ?? 0) > 0 ? " · \(files!.count)" : ""), on: tab == .files) { tab = .files }
            tabChip("Корзина" + (trash.isEmpty ? "" : " · \(trash.count)"), on: tab == .trash) { tab = .trash }
            Spacer()
            if tab == .trash && !trash.isEmpty {
                Button("Удалить всё") { confirmEmpty = true }
                    .font(nfont(14.5))
                    .foregroundStyle(Color.naomiErr)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
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

    // ── Поиск + фильтры (клиентские — данных немного, сервер не дёргаем) ──

    private var filtersBar: some View {
        VStack(spacing: 8) {
            TextField("поиск: колбаса, чек, лодка…", text: $query)
                .font(nfont(15.5))
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.naomiBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("фото", on: typeFilter == "photo") { typeFilter = typeFilter == "photo" ? nil : "photo" }
                    chip("доки", on: typeFilter == "doc") { typeFilter = typeFilter == "doc" ? nil : "doc" }
                    chip("веб", on: channelFilter == "web") { channelFilter = channelFilter == "web" ? nil : "web" }
                    chip("телега", on: channelFilter == "telegram") { channelFilter = channelFilter == "telegram" ? nil : "telegram" }
                    chip("стол", on: channelFilter == "inbox") { channelFilter = channelFilter == "inbox" ? nil : "inbox" }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(nfont(14))
                .foregroundStyle(on ? Color.primary : Color.naomiMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(on ? AnyShapeStyle(Color.naomiBubble) : AnyShapeStyle(Color.primary.opacity(0.05)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // ── Список ──

    @ViewBuilder
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if failed {
                    waitText("сервер не отвечает — список не обновляется", err: true)
                }
                if tab == .files {
                    filesList
                } else {
                    trashList
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var filesList: some View {
        let shown = filtered(files ?? [])
        if files == nil {
            if !failed { waitText("загружаю…") }
        } else if files!.isEmpty {
            waitText("склад пуст — пришли Наоми фото или файл, или кинь его в папку «Наоми — входящие» на рабочем столе")
        } else if shown.isEmpty {
            waitText("ничего не нашлось — поменяй запрос или сними фильтры")
        } else {
            // Склад группируем по дням (новые сверху — сервер уже так отдаёт).
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupByDate(shown), id: \.date) { g in
                    Section {
                        VStack(spacing: 8) {
                            ForEach(g.items, id: \.rel) { card($0, inTrash: false) }
                        }
                        .padding(.bottom, 8)
                    } header: {
                        dayHeader(g.label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trashList: some View {
        let shown = filtered(trash)
        if trash.isEmpty {
            waitText("корзина пуста")
        } else if shown.isEmpty {
            waitText("ничего не нашлось — поменяй запрос или сними фильтры")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(shown, id: \.rel) { card($0, inTrash: true) }
            }
        }
    }

    private func dayHeader(_ label: String) -> some View {
        Text(label)
            .textCase(.uppercase)
            .font(nfont(12, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(Color.naomiMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .background(Color.naomiBg)   // липкая — лента не просвечивает
    }

    // ── Карточка файла ──

    private func card(_ f: NaomiAPI.FileEntry, inTrash: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            thumb(f, inTrash: inTrash)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name ?? f.rel)
                    .font(nfont(15, weight: .semibold))
                    .lineLimit(1)
                descrText(f)
                Text(metaLine(f, inTrash: inTrash))
                    .font(nfont(12))
                    .foregroundStyle(Color.naomiMuted.opacity(0.85))
                    .padding(.top, 1)
            }
            Spacer(minLength: 6)
            actions(f, inTrash: inTrash)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.naomiBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Пока действие в полёте — карточка пригашена и не жмётся.
        .opacity(busyRel == f.rel ? 0.45 : 1)
        .allowsHitTesting(busyRel != f.rel)
    }

    @ViewBuilder
    private func descrText(_ f: NaomiAPI.FileEntry) -> some View {
        let queued = annotating.contains(f.rel)
        let text = f.descr ?? (queued ? "опись запущена — карточка появится через минуту-другую…" : "без описания в картотеке")
        Text(text)
            .font(nfont(13.5))
            .foregroundStyle(Color.naomiMuted)
            .italic(f.descr == nil)
            .opacity(f.descr == nil ? 0.75 : 1)
            .lineLimit(2)
    }

    private func thumb(_ f: NaomiAPI.FileEntry, inTrash: Bool) -> some View {
        Group {
            if f.kind == "photo" {
                RemoteImage(rel: f.rel, trash: inTrash)
            } else {
                ZStack {
                    Color.primary.opacity(0.05)
                    Image(systemName: "doc.text")
                        .font(nfont(20))
                        .foregroundStyle(Color.naomiMuted)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            if f.kind == "photo" { lightbox = FLLightbox(rel: f.rel, trash: inTrash) }
        }
    }

    private func actions(_ f: NaomiAPI.FileEntry, inTrash: Bool) -> some View {
        VStack(spacing: 6) {
            if inTrash {
                // Восстановить: файл вернётся на склад, Наоми вспомнит.
                actButton("arrow.uturn.backward") { act("restore", f) }
            } else {
                if f.descr == nil && !annotating.contains(f.rel) {
                    // Описать: Наоми рассмотрит файл и занесёт карточку в картотеку.
                    actButton("sparkles") { act("annotate", f) }
                }
                // В корзину: Наоми забудет этот файл (мягко, можно вернуть).
                actButton("trash") { act("delete", f) }
            }
        }
    }

    private func actButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(nfont(14))
                .foregroundStyle(Color.naomiMuted)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func waitText(_ s: String, err: Bool = false) -> some View {
        Text(s)
            .font(nfont(14.5))
            .foregroundStyle(err ? Color.naomiErr : Color.naomiMuted)
            .padding(.vertical, 4)
    }

    // ── Действия ──

    private func act(_ kind: String, _ f: NaomiAPI.FileEntry) {
        if kind == "annotate" {
            annotating.insert(f.rel)
            Task { try? await NaomiAPI.fileAction("api/files/annotate", rel: f.rel) }
            return
        }
        guard busyRel == nil else { return }
        busyRel = f.rel
        Task {
            do { try await NaomiAPI.fileAction(kind == "delete" ? "api/files/delete" : "api/files/restore", rel: f.rel) }
            catch { failed = true }
            await load()
            busyRel = nil
        }
    }

    private func emptyAll() {
        Task {
            do { try await NaomiAPI.emptyTrash() } catch { failed = true }
            await load()
        }
    }

    // ── Данные ──

    private func load() async {
        do {
            async let a = NaomiAPI.files()
            async let b = NaomiAPI.trashFiles()
            let (fa, tb) = try await (a, b)
            files = fa
            trash = tb
            failed = false
            // Опись доехала (описание появилось) или файл пропал — снимаем «в очереди».
            annotating = Set(annotating.filter { rel in fa.contains { $0.rel == rel && $0.descr == nil } })
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func filtered(_ list: [NaomiAPI.FileEntry]) -> [NaomiAPI.FileEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return list.filter { f in
            (typeFilter == nil || f.kind == typeFilter)
                && (channelFilter == nil || f.channel == channelFilter)
                && (q.isEmpty || ((f.name ?? "") + " " + (f.descr ?? "") + " " + f.rel).lowercased().contains(q))
        }
    }

    private struct FLGroup {
        let date: String
        let label: String
        var items: [NaomiAPI.FileEntry]
    }

    private func groupByDate(_ list: [NaomiAPI.FileEntry]) -> [FLGroup] {
        var out: [FLGroup] = []
        var cur = ""
        for f in list {
            let d = f.date ?? ""
            if d != cur {
                out.append(FLGroup(date: d, label: dayLabel(d), items: []))
                cur = d
            }
            out[out.count - 1].items.append(f)
        }
        return out
    }

    // «2026-07-06» → Сегодня / Вчера / 6 июля 2026 (как flDayLabel в вебе).
    private func dayLabel(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return dateStr }
        let cal = Calendar.current
        guard let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return dateStr }
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        return "\(parts[2]) \(flMonths[parts[1] - 1]) \(parts[0])"
    }

    // Для корзины: «удалён 6 июля, 20:15».
    private func flStamp(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let c = Calendar.current.dateComponents([.day, .month, .hour, .minute], from: d)
        return "\(c.day ?? 0) \(flMonths[(c.month ?? 1) - 1]), " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func sizeLabel(_ b: Int) -> String {
        if b < 1024 { return "\(b) Б" }
        if b < 1_048_576 { return "\(Int((Double(b) / 1024).rounded())) КБ" }
        return String(format: "%.1f", Double(b) / 1_048_576).replacingOccurrences(of: ".", with: ",") + " МБ"
    }

    private func metaLine(_ f: NaomiAPI.FileEntry, inTrash: Bool) -> String {
        var bits: [String] = []
        if let t = f.time, !t.isEmpty { bits.append(t) }
        if let ch = f.channel, let ru = flChannels[ch] { bits.append(ru) }
        if let s = f.size { bits.append(sizeLabel(s)) }
        let meta = bits.joined(separator: " · ")
        if inTrash, let ts = f.deletedTs {
            let stamp = "удалён " + flStamp(ts)
            return meta.isEmpty ? stamp : stamp + " · " + meta
        }
        return meta
    }
}

#Preview {
    FilesView()
}
