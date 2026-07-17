// Экран чата — как веб-вкладка, один в один: лента пузырей сверху, поле ввода снизу.
import SwiftUI
import PhotosUI
import UIKit   // фоновая передышка (beginBackgroundTask), чтобы короткий ответ дошёл при сворачивании
import ObjectiveC.runtime

// Фото, выбранное к отправке: миниатюра на руках сразу, загрузка на склад — в фоне.
struct PendingAttachment: Identifiable {
    let id = UUID()
    var thumb: UIImage?
    var uploaded: NaomiAPI.UploadedAttachment?   // nil — ещё едет на сервер
    var failed = false                           // не доехало: ⚠️ на миниатюре, убрать крестиком
}

// Коробка внеразметочного состояния прокрутки. Живёт в @State ради постоянства, но
// менять её поля можно без перерисовки экрана (ссылка на класс не меняется) — задачам
// прокрутки незачем инвалидировать ленту. См. комментарий у scrollTasks в ChatView.
// Подъезд ленты за клавиатурой коробка больше не обслуживает: смену РАЗМЕРА вьюпорта
// ведёт системный якорь (см. bottomAnchoredStart) — сам, синхронно с клавиатурой.
private final class ScrollTaskBox {
    var older: Task<Void, Never>?   // возврат якоря после подгрузки старых сообщений
    var tailNudge: Task<Void, Never>?   // мягкий подъезд к дну: новый ряд / новая строка
}

// Telegram не отдаёт жест системному UIScrollView: он сам ведёт слой клавиатуры и
// собственную раскладку чата, а потом решает — закрыть её или вернуть пружиной. Ниже
// тот же приём для тестовой сборки на личный телефон. В iOS НЕТ публичного API для
// сдвига живой системной клавиатуры: доступ к её окну здесь идёт через runtime. Это
// намеренно изолировано в одном мосте, имеет fallback (ничего не делает, если iOS
// изменила внутреннее устройство) и НЕ годится для версии, отправляемой в App Store.
private enum InteractiveKeyboardFinish {
    case restore
    case dismiss
}

// Единый физический профиль финала: системный слой клавиатуры получает его через
// Core Animation, а поле ввода — через SwiftUI.
private enum InteractiveKeyboardMotion {
    static let mass: Double = 1
    // Та же форма пружины, но примерно на 20% спокойнее прежней 340/31.
    // Отношение damping / sqrt(stiffness) сохранено: финал стал медленнее,
    // не превратившись при этом в резиновый отскок.
    static let stiffness: Double = 240
    static let damping: Double = 26

    static func normalizedVelocity(_ rawVelocity: CGFloat) -> Double {
        max(-4, min(4, Double(rawVelocity / 1_000)))
    }

    static func animation(initialVelocity: CGFloat) -> Animation {
        .interpolatingSpring(
            mass: mass,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: normalizedVelocity(initialVelocity)
        )
    }
}

// Не UIPanGestureRecognizer: тот соревнуется с pan самой ленты и проигрывает ему.
// Этот recognizer намеренно остаётся .possible до конца касания — как WindowPanRecognizer
// Telegram — и потому только наблюдает за пальцем, не мешая ни ScrollView, ни TextField.
private final class PassiveKeyboardPanRecognizer: UIGestureRecognizer {
    var began: ((CGPoint) -> Void)?
    var moved: ((CGPoint) -> Void)?
    var ended: ((CGPoint, CGPoint?) -> Void)?

    private var points: [(CGPoint, CFTimeInterval)] = []

    override func reset() {
        super.reset()
        points.removeAll()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        record(point)
        began?(point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        record(point)
        moved?(point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        record(point)
        ended?(point, CGPoint(x: 0, y: verticalVelocity()))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        let point = touches.first?.location(in: view) ?? .zero
        ended?(point, nil)
        state = .cancelled
    }

    private func record(_ point: CGPoint) {
        points.append((point, CACurrentMediaTime()))
        if points.count > 6 { points.removeFirst() }
    }

    private func verticalVelocity() -> CGFloat {
        let now = CACurrentMediaTime()
        var total: CGFloat = 0
        var count = 0
        for index in 1..<points.count where points[index].1 >= now - 0.1 {
            let previous = points[index - 1]
            let current = points[index]
            let elapsed = current.1 - previous.1
            guard elapsed > 0 else { continue }
            total += (current.0.y - previous.0.y) / elapsed
            count += 1
        }
        // Telegram намеренно приглушает сырую скорость в пять раз, а затем
        // сравнивает результат с порогом 100. Сохраняем обе части формулы вместе:
        // это эквивалентно примерно 500 pt/s реальной скорости пальца.
        return count == 0 ? 0 : total / CGFloat(count * 5)
    }
}

private struct TelegramKeyboardPanBridge: UIViewRepresentable {
    let inputFocused: Bool
    let keyboardHeight: CGFloat
    let resetGeneration: Int
    // «Лента у самого дна?» — спрашиваем в момент КАСАНИЯ (touchesBegan), пока палец
    // ещё ничего не утащил: к концу жеста прокрутка уже уехала, и по ней не понять,
    // был ли это «закрой клавиатуру от последнего ответа» или листание истории.
    let chatAtBottom: () -> Bool
    let onBegin: () -> Void
    let onOffset: (CGFloat) -> Void
    let onFinish: (InteractiveKeyboardFinish, CGFloat, Bool) -> Void
    let onAnimationComplete: (InteractiveKeyboardFinish) -> Void
    let onRequestDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> KeyboardPanProbe {
        let probe = KeyboardPanProbe()
        probe.hostChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return probe
    }

    func updateUIView(_ probe: KeyboardPanProbe, context: Context) {
        context.coordinator.update(from: self)
        // Нужен общий предок ScrollView и поля ввода. superview bridge — всего лишь
        // прозрачный сосед ленты, на нём UIKit чужие касания не наблюдает.
        context.coordinator.install(on: probe.window)
    }

    static func dismantleUIView(_ uiView: KeyboardPanProbe, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let pan = PassiveKeyboardPanRecognizer()
        private weak var installedHost: UIView?
        private weak var keyboardView: UIView?
        private var originalBounds: CGRect?
        private var startPoint: CGPoint?
        private var keyboardTop: CGFloat?
        private var activeKeyboardHeight: CGFloat = 0
        private var moved = false
        private var completingDismiss = false
        private var keyboardAnimationDisplayLink: CADisplayLink?
        private var keyboardAnimationDeadline: CFTimeInterval = 0
        private var keyboardAnimationFinish: InteractiveKeyboardFinish?
        private var lastResetGeneration = -1

        private var inputFocused = false
        private var keyboardHeight: CGFloat = 0
        private var chatAtBottom: () -> Bool = { false }
        private var startedAtBottom = false
        private var onBegin: () -> Void = {}
        private var onOffset: (CGFloat) -> Void = { _ in }
        private var onFinish: (InteractiveKeyboardFinish, CGFloat, Bool) -> Void = { _, _, _ in }
        private var onAnimationComplete: (InteractiveKeyboardFinish) -> Void = { _ in }
        private var onRequestDismiss: () -> Void = {}

        override init() {
            super.init()
            pan.delegate = self
            // Ровно настройки WindowPanRecognizer Telegram: касание не задерживаем
            // и не отменяем, мы его лишь читаем параллельно с настоящей лентой.
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.began = { [weak self] point in self?.beginTracking(at: point) }
            pan.moved = { [weak self] point in self?.moveTracking(to: point) }
            pan.ended = { [weak self] point, velocity in
                self?.endTracking(at: point, velocity: velocity)
            }
        }

        func update(from bridge: TelegramKeyboardPanBridge) {
            inputFocused = bridge.inputFocused
            keyboardHeight = bridge.keyboardHeight
            chatAtBottom = bridge.chatAtBottom
            onBegin = bridge.onBegin
            onOffset = bridge.onOffset
            onFinish = bridge.onFinish
            onAnimationComplete = bridge.onAnimationComplete
            onRequestDismiss = bridge.onRequestDismiss

            if bridge.resetGeneration != lastResetGeneration {
                lastResetGeneration = bridge.resetGeneration
                resetKeyboardLayer()
            }
        }

        func install(on host: UIView?) {
            guard let host, installedHost !== host else { return }
            installedHost?.removeGestureRecognizer(pan)
            host.addGestureRecognizer(pan)
            installedHost = host
            disableSystemKeyboardDismissal(in: host)
        }

        func remove() {
            resetKeyboardLayer()
            installedHost?.removeGestureRecognizer(pan)
            installedHost = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Telegram отсекает лишь нижние 44 pt (системная полоска/клавиатурный
            // край), а не всё поле. Поэтому жест, начатый на «облачке» ввода, теперь
            // тоже живой — именно это ты заметил в Telegram.
            guard gestureRecognizer === pan, let host = installedHost else { return false }
            return touch.location(in: host).y < host.bounds.height - 44
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Не соревнуемся со скроллом: он продолжает обычную прокрутку, пока
            // bridge не распознает реальное перетаскивание клавиатуры.
            if let scrollView = otherGestureRecognizer.view as? UIScrollView,
               otherGestureRecognizer === scrollView.panGestureRecognizer,
               scrollView.alwaysBounceVertical || scrollView.contentSize.height > scrollView.bounds.height {
                scrollView.keyboardDismissMode = .none
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func beginTracking(at point: CGPoint) {
            guard !completingDismiss else {
                return
            }
            guard let view = findKeyboardView() else {
                return
            }
            let frame = view.convert(view.bounds, to: installedHost)
            let height = max(keyboardHeight, view.bounds.height)
            // Контейнер остаётся в дереве и после hide, но уезжает ниже экрана.
            // Берём реальную геометрию вместо @FocusState: SwiftUI может обновить
            // binding раньше, чем UIKit закончит живой жест.
            guard height > 0, !view.isHidden,
                  frame.minY < (installedHost?.bounds.maxY ?? UIScreen.main.bounds.maxY) - 1 else {
                return
            }
            keyboardView = view
            originalBounds = view.layer.bounds
            startPoint = point
            keyboardTop = frame.minY
            activeKeyboardHeight = height
            moved = false
            // Снимок «у дна» — ровно в момент касания, до первого сдвига пальца.
            startedAtBottom = chatAtBottom()
        }

        private func moveTracking(to point: CGPoint) {
            guard startPoint != nil, let keyboardView, let originalBounds,
                  let keyboardTop else { return }
            // Как в Telegram: лента доезжает до клавиатуры сама, а тянуть её
            // начинаем ровно с момента, когда палец пересёк верхний край.
            let offset = min(max(0, point.y - keyboardTop), activeKeyboardHeight)
            guard offset > 0 else { return }
            if !moved {
                moved = true
                onBegin()
            }
            setKeyboardOffset(offset, on: keyboardView, originalBounds: originalBounds)
            onOffset(offset)
        }

        private func endTracking(at point: CGPoint, velocity: CGPoint?) {
            guard moved, let keyboardView, let originalBounds, startPoint != nil else {
                self.keyboardView = nil
                self.originalBounds = nil
                startPoint = nil
                moved = false
                return
            }

            let offset = min(max(0, point.y - (keyboardTop ?? point.y)), activeKeyboardHeight)
            let verticalVelocity = velocity?.y ?? 0
            // У Telegram два равноправных финала: клавиатуру либо довели до низа,
            // либо отпустили с направленной вниз скоростью > 100 после их
            // нормализации (около 500 pt/s до деления на 5). Оставляем прежний
            // допуск 8% у физического края, чтобы не менять уже настроенный полный
            // протяг. Быстрый свайп, лишь задевший клавиатуру, продолжит закрытие
            // сам; медленный короткий протяг всё ещё вернётся пружиной.
            let reachedBottom = offset >= activeKeyboardHeight * 0.92
            let fastDownwardFlick = verticalVelocity > 100
            let shouldDismiss = velocity != nil && (reachedBottom || fastDownwardFlick)
            let target = shouldDismiss ? activeKeyboardHeight : 0
            let animationDuration = animateKeyboard(
                to: target,
                on: keyboardView,
                originalBounds: originalBounds,
                initialVelocity: verticalVelocity
            )
            let finish: InteractiveKeyboardFinish = shouldDismiss ? .dismiss : .restore
            onFinish(finish, verticalVelocity, startedAtBottom)
            followKeyboardAnimation(
                finish: finish,
                duration: animationDuration
            )

            if shouldDismiss {
                // Bounds нужны до keyboardDidHide: тогда вернём слой в исходное
                // состояние уже за невидимой клавиатурой, без вспышки при новом фокусе.
                completingDismiss = true
            }
            self.startPoint = nil
            self.keyboardTop = nil
            self.activeKeyboardHeight = 0
            moved = false
        }

        private func followKeyboardAnimation(finish: InteractiveKeyboardFinish,
                                             duration: CFTimeInterval) {
            stopFollowingKeyboardAnimation()
            keyboardAnimationFinish = finish
            keyboardAnimationDeadline = CACurrentMediaTime() + duration

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(stepKeyboardAnimation)
            )
            keyboardAnimationDisplayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
        }

        @objc private func stepKeyboardAnimation(_ displayLink: CADisplayLink) {
            guard keyboardView != nil, let finish = keyboardAnimationFinish else {
                stopFollowingKeyboardAnimation()
                return
            }

            guard CACurrentMediaTime() >= keyboardAnimationDeadline else { return }
            stopFollowingKeyboardAnimation()
            onAnimationComplete(finish)

            if finish == .dismiss {
                guard completingDismiss else { return }
                onRequestDismiss()
            } else {
                self.keyboardView = nil
                self.originalBounds = nil
            }
        }

        private func stopFollowingKeyboardAnimation() {
            keyboardAnimationDisplayLink?.invalidate()
            keyboardAnimationDisplayLink = nil
            keyboardAnimationFinish = nil
            keyboardAnimationDeadline = 0
        }

        private func setKeyboardOffset(_ offset: CGFloat, on view: UIView, originalBounds: CGRect) {
            var bounds = originalBounds
            bounds.origin.y -= offset
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer.removeAnimation(forKey: "naomi.keyboard.spring")
            view.layer.bounds = bounds
            CATransaction.commit()
        }

        private func animateKeyboard(to offset: CGFloat, on view: UIView, originalBounds: CGRect,
                                     initialVelocity: CGFloat) -> CFTimeInterval {
            let layer = view.layer
            let currentY = (layer.presentation() ?? layer).bounds.origin.y
            var targetBounds = originalBounds
            targetBounds.origin.y -= offset

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.bounds = targetBounds
            CATransaction.commit()

            let spring = CASpringAnimation(keyPath: "bounds.origin.y")
            spring.fromValue = currentY
            spring.toValue = targetBounds.origin.y
            spring.mass = CGFloat(InteractiveKeyboardMotion.mass)
            spring.stiffness = CGFloat(InteractiveKeyboardMotion.stiffness)
            spring.damping = CGFloat(InteractiveKeyboardMotion.damping)
            spring.initialVelocity = CGFloat(
                InteractiveKeyboardMotion.normalizedVelocity(initialVelocity)
            )
            // Длительность берём из той же физики, а не режем вручную: поле, резерв
            // чата и клавиатура получают время полностью до точки покоя.
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "naomi.keyboard.spring")
            return spring.duration
        }

        private func resetKeyboardLayer() {
            stopFollowingKeyboardAnimation()
            completingDismiss = false
            startPoint = nil
            keyboardTop = nil
            activeKeyboardHeight = 0
            guard let keyboardView, let originalBounds else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            keyboardView.layer.removeAnimation(forKey: "naomi.keyboard.spring")
            keyboardView.layer.bounds = originalBounds
            CATransaction.commit()
            self.keyboardView = nil
            self.originalBounds = nil
        }

        // SwiftUI-модификатор .scrollDismissesKeyboard(.never) на iOS 26 иногда
        // не доходит до вложенного HostingScrollView. Фиксируем публичный UIKit
        // режим прямо на настоящем scroll view, чтобы системный pan не скрыл input
        // до того, как наш bridge успеет вернуть его пружиной.
        private func disableSystemKeyboardDismissal(in view: UIView) {
            if let scrollView = view as? UIScrollView {
                scrollView.keyboardDismissMode = .none
            }
            for child in view.subviews {
                disableSystemKeyboardDismissal(in: child)
            }
        }

        // internalGetKeyboard в Telegram — не системный метод UIApplication, а их
        // собственная Objective-C обёртка над class-методом UIRemoteKeyboardWindow.
        // Вызываем тот же метод через runtime: это возвращает настоящее удалённое
        // окно с UIInputSetHostView, слой которого двигает именно клавиши.
        private func findKeyboardView() -> UIView? {
            if let keyboardWindow = remoteKeyboardWindow(),
               let host = keyboardHost(in: keyboardWindow) {
                return host
            }

            let keyboardWindows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .filter { window in
                    let name = NSStringFromClass(type(of: window))
                    return name.hasSuffix("RemoteKeyboardWindow") || name.hasSuffix("TextEffectsWindow")
                }
            for keyboardWindow in keyboardWindows {
                if let host = keyboardHost(in: keyboardWindow) { return host }
            }
            return nil
        }

        private func remoteKeyboardWindow() -> UIWindow? {
            guard let windowClass = NSClassFromString("UIRemoteKeyboardWindow") else { return nil }
            let selector = NSSelectorFromString("remoteKeyboardWindowForScreen:create:")
            guard let method = class_getClassMethod(windowClass, selector) else { return nil }

            typealias GetRemoteKeyboardWindow = @convention(c) (
                AnyObject, Selector, AnyObject, Bool
            ) -> Unmanaged<AnyObject>?
            let implementation = method_getImplementation(method)
            let call = unsafeBitCast(implementation, to: GetRemoteKeyboardWindow.self)
            return call(windowClass, selector, UIScreen.main, false)?.takeUnretainedValue() as? UIWindow
        }

        private func keyboardHost(in view: UIView) -> UIView? {
            let name = NSStringFromClass(type(of: view))
            if name.hasSuffix("InputSetHostView") || name.hasSuffix("KeyboardItemContainerView") {
                return view
            }
            for subview in view.subviews {
                if let found = keyboardHost(in: subview) { return found }
            }
            return nil
        }
    }

    final class KeyboardPanProbe: UIView {
        var hostChanged: ((UIView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hostChanged?(window)
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            hostChanged?(window)
        }
    }
}

// Возврат ленты к дну после жеста-скрытия клавиатуры, начатого у дна. Такой свайп —
// это ещё и обычный pan ленты: палец успевает утащить чат в историю, а инерция после
// отпускания везёт дальше — последний ответ уезжает под облачко ввода. Если жест
// НАЧАЛСЯ у дна, финал должен быть тем же дном: инерцию глушим и ведём офсет к нижней
// границе той же физикой, что финал клавиатуры (жёсткость семьи 240, демпфер
// критический — приезд без отскока, никаких видимых пружин). Цель пересчитывается
// КАЖДЫЙ кадр по живой геометрии: параллельно режется резерв ленты (chatReserveCut),
// стрим может дописывать строки — а якорь sizeChanges сдвигает офсет и цель на одну
// и ту же величину, так что пружина этих перестроек даже не чувствует. Рука главнее:
// новое касание ленты (isTracking) или фокус поля — и возврат молча отменяется.
private final class ChatScrollPinBox: NSObject {
    // Живое расстояние видимого низа до конца контента — зеркалится каждым кадром
    // прокрутки (см. trackBottomDistance) в поле класса, мимо @State: перерисовок
    // не дёргает. Стартовое «бесконечно далеко» = на iOS без датчика (<18) возврат
    // просто никогда не включается.
    var distanceToBottom: CGFloat = .greatestFiniteMagnitude
    weak var scrollView: UIScrollView?

    private var displayLink: CADisplayLink?
    private var velocity: CGFloat = 0
    private var lastTick: CFTimeInterval = 0
    private var onSettled: (() -> Void)?

    private let stiffness: CGFloat = 240   // семья InteractiveKeyboardMotion
    private let damping: CGFloat = 31      // ≈ 2·√240 — критическое, без перелёта

    // fingerVelocity — настоящая скорость пальца (pt/s, вниз положительная). Палец
    // вёл контент вниз — офсет летел в минус: отдаём пружине ту же скорость, чтобы
    // остановка была продолжением движения (чуть донесёт и мягко вернёт), а не ступенькой.
    func pin(fingerVelocity: CGFloat, onSettled: @escaping () -> Void) {
        guard scrollView != nil else { return }
        cancel()
        self.onSettled = onSettled
        velocity = -min(max(fingerVelocity, -3000), 3000)
        stopDeceleration()
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        onSettled = nil
    }

    // Классический публичный способ заглушить инерцию: «остановись на текущем месте».
    private func stopDeceleration() {
        guard let scrollView, scrollView.isDecelerating else { return }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView, !scrollView.isTracking else {
            cancel()   // лента исчезла или её снова взяли рукой — палец главнее
            return
        }
        // Порядок окончания жестов окна и ленты не гарантирован: системная инерция
        // могла стартовать уже ПОСЛЕ pin — глушим её, как только замечаем.
        stopDeceleration()

        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30))   // крышка на случай подвиса кадров
        lastTick = now

        let inset = scrollView.adjustedContentInset
        let minOffset = -inset.top
        let target = max(
            minOffset,
            scrollView.contentSize.height + inset.bottom - scrollView.bounds.height
        )
        // Отклонение пересчитываем от ЖИВОГО офсета: чужие сдвиги (якорь sizeChanges
        // при срезе резерва) не копятся в ошибку, пружина продолжает от факта.
        var x = scrollView.contentOffset.y - target
        let acceleration = -stiffness * x - damping * velocity
        velocity += acceleration * dt
        x += velocity * dt

        if abs(x) < 0.5, abs(velocity) < 12 {
            scrollView.contentOffset.y = target
            let done = onSettled
            cancel()
            done?()
            return
        }
        // Кламп сверху: за дно (под облачко ввода) не заезжаем ни на кадр.
        scrollView.contentOffset.y = min(max(target + x, minOffset), target)
    }
}

// «У самого дна» для возврата после жеста-скрытия: строже общего порога 150 —
// прижатие не должно красть позицию, когда Слава чуть отлистал и читает хвост
// длинного ответа. 40 пт покрывает дрожь дна (недоехавший nudge, доли строки).
private let chatBottomPinThreshold: CGFloat = 40

// У системной bounce-пружины UIScrollView нет публичной настройки длительности.
// Этот probe живёт ВНУТРИ контента именно чатовой ленты и настраивает ближайший
// UIScrollView публичным способом: bounce оставляем, но скорость гасим примерно
// вдвое сильнее (.996 против системных .998). До границы доезжает меньше энергии —
// перелёт получается короче и слабее, возврат заканчивается заметно быстрее.
private struct ChatScrollPhysicsConfigurator: UIViewRepresentable {
    let pinBox: ChatScrollPinBox

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.pinBox = pinBox
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.pinBox = pinBox
        uiView.configureNearestScrollView()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Void) {
        uiView.restoreConfiguredScrollView()
    }

    final class ProbeView: UIView {
        var pinBox: ChatScrollPinBox?
        private weak var configuredScrollView: UIScrollView?
        private var originalBounces: Bool?
        private var originalDecelerationRate: UIScrollView.DecelerationRate?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            configureNearestScrollView()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureNearestScrollView()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            configureNearestScrollView()
        }

        func configureNearestScrollView() {
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) {
                ancestor = current.superview
            }
            guard let scrollView = ancestor as? UIScrollView else { return }
            // Той же находкой пользуется возврат к дну: коробке нужен настоящий
            // UIScrollView, чтобы глушить инерцию и вести офсет.
            pinBox?.scrollView = scrollView

            if configuredScrollView !== scrollView {
                restoreConfiguredScrollView()
                configuredScrollView = scrollView
                originalBounces = scrollView.bounces
                originalDecelerationRate = scrollView.decelerationRate
            }

            // SwiftUI может повторно применить свои настройки при обновлении дерева,
            // поэтому подтверждаем значения и в update/layout, а не только один раз.
            scrollView.bounces = true
            scrollView.decelerationRate = .init(rawValue: 0.996)
        }

        func restoreConfiguredScrollView() {
            if let scrollView = configuredScrollView {
                if let originalBounces { scrollView.bounces = originalBounces }
                if let originalDecelerationRate {
                    scrollView.decelerationRate = originalDecelerationRate
                }
            }
            configuredScrollView = nil
            originalBounces = nil
            originalDecelerationRate = nil
        }
    }
}

// Хвост ленты (маркер-«дно») — общий id для колонки пузырей и обработчиков прокрутки.
private let chatTailID = "chat-tail"

// Высота живой панели меняется при многострочном тексте и вложениях. Ленте нужен
// ровно такой же нижний inset, пока сама панель рисуется независимым overlay.
private struct InputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 50

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Колонка пузырей вынесена в ОТДЕЛЬНЫЙ Equatable-вид: пока сами сообщения не изменились,
// SwiftUI её пропускает (== вернёт true) и НЕ пересобирает 80 пузырей. Раньше лента жила
// прямо в body экрана и перетряхивалась на каждый чих состояния прокрутки — это и есть
// тот главный поток, что «поддёргивал» и скролл, и сворачивание клавиатуры.
// В колонке — только ЗАСТЫВШИЕ ряды (все, кроме последнего): последний ряд во время
// стрима мутирует каждым словом, и живи он здесь — тик перетряхивал бы все пузыри окна.
// Он рисуется отдельно, рядом с колонкой (см. messagesList), тик стоит один пузырь.
// Биндинг lightbox и замыкание onRetry в сравнении не участвуют (их и не с чем сверять),
// но пишут в стабильное хранилище — работают даже когда вид пропущен.
private struct BubbleColumn: View, Equatable {
    @Environment(\.naomiTheme) private var theme
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
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryText)
            Button("Попробовать ещё раз", action: onRetry)
                .font(.subheadline.weight(.medium))
                .tint(theme.accent)
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
    @Environment(\.naomiTheme) private var theme
    private let previewMode: Bool
    // Фаза сцены: возврат из фона — повод тихо перечитать историю (Мак мог дописать
    // ответ или прислать автоматику/напоминалку, пока телефон спал). См. .onChange ниже.
    @Environment(\.scenePhase) private var scenePhase
    // Холодный старт — сразу со слепком с телефона: чат виден мгновенно,
    // сеть догоняет в фоне (loadHistory) и тихо обновляет, если что-то изменилось.
    @State private var messages: [ChatMessage] = ChatCache.load()
    @State private var input = ""
    @State private var sending = false
    @State private var loadError: String?
    // Свернули приложение прямо во время ответа? Тогда обрыв стрима — это НЕ «не
    // дозвонилась» (Мак на месте, ход доигрывает сам), а сигнал подтянуть готовый ответ
    // из истории при возврате. Ставится в .onChange(scenePhase), гасится в начале send().
    @State private var leftForegroundMidSend = false
    // Живой ход из общего канала /api/events (запущен НЕ с телефона — телеграм/автоматика —
    // или нами, но приложение перезашло посреди): рисуем теми же плашками/стримом, что и свой
    // ход. Ряды помечаем в liveRowIDs, чтобы сбросить всю группу разом при пересборке/обрыве.
    @State private var liveActive = false
    @State private var liveChipID: UUID?
    @State private var liveReplyID: UUID?
    @State private var liveRowIDs: [UUID] = []
    @State private var busTask: Task<Void, Never>?
    // Уходили в настоящий фон? На возврате пересобираем живой ход и сверяемся с историей
    // (пока спали, ход мог закончиться или уйти дальше). Отличаем фон от транзитного .inactive.
    @State private var wasBackgrounded = false
    @FocusState private var inputFocused: Bool
    // Отложенные прокрутки (возврат якоря окна и подъезд к дну) держим в классе-коробке,
    // а НЕ в @State: переустановка задачи не должна перерисовывать экран. Раньше они
    // жили в @State — и каждая переустановка дёргала пересборку всей ленты.
    @State private var scrollTasks = ScrollTaskBox()
    // Возврат ленты к дну после жеста-скрытия клавиатуры, начатого у дна: коробка
    // глушит инерцию и пружиной сажает последний ответ над облачком ввода
    // (см. ChatScrollPinBox). Ссылка стабильна, её поля меняются без перерисовок.
    @State private var scrollPin = ChatScrollPinBox()
    // «Якорь сорван»: пользователь взял ленту рукой. Палец срывает якорь МГНОВЕННО —
    // автопрокрутка стрима не смеет дёргать чат из-под пальца; обратно якорь цепляется,
    // когда жест улёгся у дна (см. trackScroll), или отправкой сообщения (send()).
    @State private var scrolledAwayByHand = false
    // Лента у дна? (запас 150 пт; перелёт пружины за дно — тоже «у дна».) Нужен одному
    // месту: тапу в поле ввода во время пружины — факт «доехал до конца» помнится,
    // даже пока лента отскакивает, и клавиатура поднимает чат с собой (см. onChange
    // inputFocused). Глубоко в истории остаётся false — там ничего не дёргаем.
    @State private var isNearBottom = true
    // Фокус во время нижнего bounce нельзя запускать параллельно с его пружиной:
    // UIScrollView ещё ведёт contentOffset к старому дну, а клавиатура уже меняет
    // viewport. Тап не теряем — ставим в очередь до настоящей системной фазы .idle.
    @State private var chatScrollIsIdle = true
    @State private var pendingBottomInputFocus = false
    // Свой интерактивный жест клавиатуры (как у Telegram). Высоту берём из системных
    // нотификаций, а offset рисуем сами — при таком drag iOS не меняет safe area.
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardDragOffset: CGFloat = 0
    @State private var keyboardDragging = false
    @State private var keyboardResetGeneration = 0
    // В финале dismiss резерв ленты отрезается одинаково при любой позиции чата.
    // Отдельной ветки для последнего ответа намеренно нет: она вмешивалась в живой
    // pan UIScrollView и отстреливала ленту вверх, когда палец заходил на клавиатуру.
    @State private var chatReserveCut = false
    // Читаем один раз после первого layout. Нельзя обращаться к window.safeAreaInsets
    // из computed property body: safeAreaBar сам рассчитывает этот inset и образует
    // AttributeGraph cycle (чёрный экран).
    @State private var deviceBottomSafeArea: CGFloat = 34
    @State private var inputBarHeight: CGFloat = 50
    // Вложения: выбор из фотоплёнки, очередь к отправке, открытое на весь экран фото.
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pendingAtts: [PendingAttachment] = []
    @State private var lightbox: LightboxItem?
    // Заставка на холодном старте: прячет, как чат встаёт на место (уловка Claude).
    @State private var showSplash = true
    // Настройки подключения (две дороги и пропуск) — по тапу на облачко «Наоми» в шапке.
    @State private var showSettings = false
    // Лента рисует не всю историю разом, а последние windowCount сообщений. Остальное
    // лежит в messages и подтягивается окном при прокрутке вверх (данные уже в памяти —
    // подгрузка мгновенная, без похода в сеть). 300 живых пузырей разом — вот что
    // проседало: на экране нужны 1–2 экрана переписки, а не вся история сразу.
    @State private var windowCount = ChatView.windowBase

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        guard previewMode else { return }
        _messages = State(initialValue: Self.previewConversation)
        _showSplash = State(initialValue: false)
    }

    private static var previewConversation: [ChatMessage] {
        var completed = ChatMessage(
            role: .assistant,
            text: "проверила палитру и собираю экран",
            kind: .action
        )
        completed.isLive = false

        var active = ChatMessage(
            role: .assistant,
            text: "подбираю оттенки интерфейса",
            kind: .action
        )
        active.isLive = true

        return [
            ChatMessage(
                role: .assistant,
                text: "Привет! Здесь можно вживую настроить каждый основной цвет чата."
            ),
            ChatMessage(
                role: .user,
                text: "Хочу тёплый фон, спокойный пузырь и более выразительное стекло."
            ),
            completed,
            active,
            ChatMessage(
                role: .assistant,
                text: "Меняй параметры справа — результат сразу появится на этом экране."
            )
        ]
    }

    var body: some View {
        ZStack {
            // Фон остаётся неподвижным, пока весь нижний chat-surface едет за
            // клавиатурой: иначе сверху на пружине открывался бы пустой участок.
            theme.background.ignoresSafeArea()

            ZStack {
                messagesList
            }
            .floatingBottomReserve(height: inputBarHeight + chatKeyboardClearance)
            // Шапка своя — облачко «Наоми» тем же механизмом, что поле ввода снизу
            // (safeAreaBar даёт родное затемнение края при заезде ленты под бар).
            // NavigationStack не нужен: навигации в приложении нет, системный навбар
            // не рисуется, а sheet/fullScreenCover живут на любом виде.
            .floatingHeaderBar { headerBar }
            .fullScreenCover(item: $lightbox) { item in
                LightboxView(rel: item.rel)
            }

            // Не зависит от keyboard safe area: положение каждый кадр задаём сами
            // по keyboardHeight − dragOffset. Поэтому у UIKit больше нет второго
            // layout-прохода, способного отстрелить поле или нижнюю тень.
            inputChromeLayer

            // Заставка холодного старта (уловка Claude): пока под ней чат встаёт на
            // место, наверху — спокойная надпись; тает — а всё уже готово. Клавиатура
            // (она в системном слое выше приложения) выезжает поверх с родной анимацией.
            if showSplash {
                splash
                    .zIndex(1)
            }
        }
        // Системная keyboard safe area больше не меняет геометрию этого экрана:
        // настоящую клавиатуру, панель и нижний резерв ленты ведёт одна и та же
        // keyboardHeight − keyboardDragOffset. Поэтому у UIKit не остаётся второго
        // layout-таймлайна после окончания нашей пружины.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Recognizer висит на окне приложения: жест не обрывается, когда палец из
        // ленты заезжает на системную клавиатуру. Сам мост прозрачен для обычных тапов.
        .overlay {
            if !previewMode {
                TelegramKeyboardPanBridge(
                    inputFocused: inputFocused,
                    keyboardHeight: keyboardHeight,
                    resetGeneration: keyboardResetGeneration,
                    chatAtBottom: { scrollPin.distanceToBottom < chatBottomPinThreshold },
                    onBegin: beginInteractiveKeyboardDrag,
                    onOffset: updateInteractiveKeyboardDrag,
                    onFinish: finishInteractiveKeyboardDrag,
                    onAnimationComplete: completeInteractiveKeyboardAnimation,
                    onRequestDismiss: { resignFocusInstantly() }
                )
                .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            updateKeyboardFrame($0)
        }
        .onPreferenceChange(InputBarHeightPreferenceKey.self) { height in
            guard height > 0, abs(inputBarHeight - height) > 0.5 else { return }
            inputBarHeight = height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            // К этому моменту окно клавиатуры уже невидимо: возвращаем его layer
            // в обычные bounds без вспышки перед следующим открытием.
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                keyboardHeight = 0
                keyboardDragOffset = 0
                keyboardDragging = false
                chatReserveCut = false   // формула при нулях тоже 0 — снятие бесшовно
            }
            keyboardResetGeneration &+= 1
        }
        .task {
            guard !previewMode else { return }
            // «Визитку» держит только системный launch screen. Наша копия заставки
            // лишь бесшовно перехватывает его на первом кадре и сразу тает,
            // одновременно выезжает клавиатура. Микро-пауза — на первую разметку
            // чата за заставкой, глазу она не видна.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                if let inset = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)?
                    .safeAreaInsets.bottom,
                   inset > 0 {
                    deviceBottomSafeArea = inset
                }
                withAnimation(.easeOut(duration: 0.60)) { showSplash = false }
                // Не ждём следующего keyboardWillChangeFrame, чтобы начать подъём
                // панели: фокус и её ожидаемая высота стартуют одним таймлайном.
                // Реальную высоту каждой показанной клавиатуры сохраняем ниже.
                let cachedHeight = CGFloat(
                    UserDefaults.standard.double(forKey: "naomi.lastKeyboardHeight")
                )
                let anticipatedHeight = cachedHeight > deviceBottomSafeArea
                    ? cachedHeight
                    : 345
                withAnimation(.easeInOut(duration: 0.25)) {
                    keyboardHeight = anticipatedHeight
                    inputFocused = true
                }
            }
            await NaomiAPI.reroute()   // выбрать дорогу (дом/туннель) до первого запроса
            await loadHistory()
            startBus()   // живой канал: слушаем идущий ход и проактивные сообщения, сам переподключается
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
                // Уходим в фон посреди отправки — запомним: обрыв стрима будет ложным.
                if sending { leftForegroundMidSend = true }
            case .active:
                // Только настоящий возврат из фона (не транзитный .inactive от шторки или
                // переключателя приложений). Пока спали, живой ход мог закончиться или уйти
                // дальше: сбрасываем его призрак, сверяемся с историей и переподключаем канал
                // сразу (не ждём таймаута мёртвого сокета). Во время своей отправки историю
                // не трогаем — там свой доподхват в конце хода (см. send()).
                if wasBackgrounded {
                    wasBackgrounded = false
                    liveReset()
                    // Пока спали, могли переехать (дом ↔ мир) — перевыбираем дорогу.
                    if !sending { Task { await NaomiAPI.reroute(); await loadHistory() } }
                    startBus()
                }
            default:
                break
            }
        }
        // Настройки подключения — по тапу на облачко «Наоми» в шапке. После «Готово»
        // адрес сервера или пропуск могли смениться — перевыбираем дорогу, перечитываем
        // историю уже у нового адреса и переподключаем живой канал.
        .sheet(isPresented: $showSettings) {
            SettingsSheet {
                Task {
                    await NaomiAPI.reroute()
                    await loadHistory()
                    startBus()
                }
            }
        }
    }

    // Шапка: облачко «Наоми» в стеклянной капсуле по центру — единственная кнопка
    // приложения, тап открывает настройки подключения. Пока идёт ход (свой после
    // отправки или живой из другого канала), надпись гаснет до плашечной и по ней
    // бежит «фонарик», как по делам в ленте, только луч уже, ярче и шустрее —
    // короткому слову мягкий плашечный пресет почти не виден.
    private var headerBar: some View {
        let busy = sending || liveActive
        return Button {
            showSettings = true
        } label: {
            Text("Наоми")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(busy ? theme.secondaryText : theme.primaryText)
                .modifier(ShimmerIf(active: busy, period: 1.4, minBand: 0, peak: 1.0))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .contentShape(Capsule())
                .titleGlassBackground()
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: busy)
    }

    // Экран-заставка: чистый тёплый фон, без надписи — бесшовно продолжает
    // системный launch screen (он такого же цвета) и тает над готовым интерфейсом.
    private var splash: some View {
        theme.background
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
                // Обычный VStack, не Lazy: ленивая разметка при смене высоты клавиатуры/поля
                // промахивалась офсетом в нерассчитанную зону — чат «исчезал». Рисуется только
                // окно windowed (старое приезжает прокруткой вверх), и оно разрезано надвое:
                // застывшие ряды — Equatable-колонка (SwiftUI её пропускает, пока ряды те же),
                // ЖИВОЙ последний ряд — отдельно. Во время стрима каждое слово мутирует только
                // его: тик пересобирает один пузырь, а не все 60 в окне.
                VStack(spacing: 12) {
                    if loadError != nil || windowed.count > 1 {
                        BubbleColumn(messages: windowed.dropLast(), loadError: loadError,
                                     lightbox: $lightbox,
                                     onRetry: { Task { await loadHistory() } })
                            .equatable()
                    }
                    if let last = windowed.last {
                        MessageBubble(message: last, onTapImage: { lightbox = LightboxItem(rel: $0) })
                            .padding(.vertical, last.role == .user ? 4 : 0)   // как в колонке
                            .id(last.id)
                    }
                    Color.clear
                        .frame(height: 14)
                        .id(chatTailID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .background {
                    ChatScrollPhysicsConfigurator(pinBox: scrollPin)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
            // У системной клавиатуры нет публичных настройки порога, скорости или
            // «пружины» interactive-dismiss. Системному ScrollView по-прежнему
            // запрещено сворачивание: его жест заменяет TelegramKeyboardPanBridge.
            .scrollDismissesKeyboard(.never)
            .bottomAnchoredStart()
            .trackScroll(nearBottom: $isNearBottom, handScrolled: $scrolledAwayByHand,
                         keyboardDragging: $keyboardDragging, isIdle: $chatScrollIsIdle)
            .trackBottomDistance(into: scrollPin)
            .onChange(of: chatScrollIsIdle) { _, isIdle in
                guard isIdle, pendingBottomInputFocus else { return }
                pendingBottomInputFocus = false

                // Если отскок действительно закончился у хвоста, сначала одним
                // неанимированным кадром фиксируем его точное дно. Если за время
                // ожидания пользователь увёл ленту выше — его позицию не трогаем.
                if isNearBottom {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                }

                // FocusState меняет резерв ленты и запускает клавиатуру. Отдаём ему
                // следующий кадр, чтобы он не попал в ту же транзакцию, где погасла
                // пружина и зафиксировался contentOffset.
                Task { @MainActor in
                    await Task.yield()
                    inputFocused = true
                }
            }
            .onChange(of: inputFocused) { _, focused in
                guard focused else { return }
                // Фокус поля — рука главнее возврата к дну после жеста-скрытия: если
                // пружина ChatScrollPinBox ещё едет, офсет дальше ведут клавиатура и
                // системный якорь, двум водителям тут не место.
                scrollPin.cancel()
                // Тап в поле, пока лента пружинит у дна: системная инерция ведёт офсет
                // к СТАРОМУ дну (посчитанному до клавиатуры) и перебивает коррекцию
                // якоря sizeChanges — клавиатура выезжала, чат оставался. Сам факт
                // «доехал до дна» (пружина-перелёт — тоже у дна) значит: вызвал
                // клавиатуру — едем вместе. Мгновенный scrollTo обрывает пружину на
                // дне ДО выезда клавиатуры, дальше обоих везёт один системный ход.
                // Стоячий чат у дна — пустой ход; глубоко в истории — не трогаем,
                // якорь сохранит видимое место сам.
                guard isNearBottom else { return }
                proxy.scrollTo(chatTailID, anchor: .bottom)
            }
            // Подтягиваем старые сообщения, когда прокрутка почти у верха окна.
            .trackNearTop { growOlder(proxy) }
            .onChange(of: messages.last?.text) {
                // Растущий ответ мягко подталкивает ленту вверх (телепорт строки
                // лечится именно анимацией) — но только пока якорь цел. Свайп во время
                // стрима срывает якорь, и лента остаётся в руке; спустился к последней
                // строчке — якорь цепляется сам, см. trackHandAnchor.
                guard !scrolledAwayByHand else { return }
                nudgeTail(proxy, duration: 0.2)
            }
            .onChange(of: messages.count) { oldCount, _ in
                guard !messages.isEmpty else { return }
                if oldCount == 0 {
                    // Первичная загрузка истории: встаём на дно мгновенно, без «киносеанса»
                    // с прокруткой всей переписки. Тихая добивка — после ленивой разметки,
                    // чтобы дно было точным.
                    proxy.scrollTo(chatTailID, anchor: .bottom)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(chatTailID, anchor: .bottom)
                    }
                } else {
                    // Новые ряды везут чат вниз, только пока якорь цел. Отправка
                    // перевзводит якорь прямо в send() — свой ход по-прежнему стартует
                    // вниз из любой глубины переписки. Но если рука сорвала якорь уже
                    // ПО ХОДУ ответа (раньше «sending ||» тащил вниз безусловно), новые
                    // слои — плашки дел, файлы — ленту не дёргают; как и чужие ряды
                    // (автоматика, зеркало телеграма), пока Слава листает старое:
                    // дочитает и спустится сам, новое будет ждать внизу.
                    guard !scrolledAwayByHand else { return }
                    nudgeTail(proxy, duration: 0.25)
                }
            }
        }
    }

    // Клавиатура уезжает на всю свою высоту, но панель ввода — меньше: в закрытом
    // состоянии она должна остановиться НАД home-indicator safe area. Раньше обеим
    // давали keyboardHeight, поэтому панель проваливалась к краю на лишние ~34 pt,
    // ждала там didHide и затем отстреливала обратно.
    private var inputBarTravelDistance: CGFloat {
        max(0, keyboardHeight - deviceBottomSafeArea)
    }

    // inputChromeLayer привязан к неизменному физическому низу экрана. Открытая
    // клавиатура задаёт полный отступ, закрытая — только home-indicator safe area.
    // В конце dismiss обе стороны дают одинаковые 34 pt, поэтому didHide ничего
    // визуально не перестраивает.
    private var inputBarBottomClearance: CGFloat {
        max(deviceBottomSafeArea, keyboardHeight - keyboardDragOffset)
    }

    // Лента уже заканчивается над container safe area, поэтому ей нужна лишь часть
    // клавиатурного отступа сверх home indicator. Это тот же источник координат,
    // что и у панели, а не отдельная системная keyboard safe area.
    private var chatKeyboardClearance: CGFloat {
        chatReserveCut ? 0 : max(0, inputBarBottomClearance - deviceBottomSafeArea)
    }

    private func beginInteractiveKeyboardDrag() {
        // Только помечаем живой keyboard-drag. Позицию и инерцию самой ленты здесь
        // не меняем — у последнего ответа действует тот же путь, что в истории.
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            keyboardDragging = true
        }
    }

    private func updateInteractiveKeyboardDrag(_ offset: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            keyboardDragOffset = min(max(0, offset), inputBarTravelDistance)
        }
    }

    private func finishInteractiveKeyboardDrag(_ finish: InteractiveKeyboardFinish,
                                               initialVelocity: CGFloat,
                                               startedAtBottom: Bool) {
        if finish == .dismiss {
            // Один путь для любой позиции ленты, включая последний ответ: конечный
            // размер применяется разом, без отдельного удержания хвоста, клампа
            // contentOffset или принудительного scrollToBottom.
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                chatReserveCut = true
            }
        }

        // Поле доигрывает пружину отдельно; геометрия самой ленты уже конечная и
        // больше не вмешивается в её живую прокрутку или инерцию.
        withAnimation(InteractiveKeyboardMotion.animation(initialVelocity: initialVelocity)) {
            keyboardDragOffset = finish == .dismiss ? inputBarTravelDistance : 0
        }

        // Жест начался у самого дна и кончился скрытием: это был «закрой клавиатуру»,
        // а не «листай историю» — но pan ленты и инерция уже утащили чат от дна.
        // Возврат ведёт ChatScrollPinBox: глушит инерцию и той же пружинной семьёй
        // сажает последний ответ над облачком ввода. Мост отдаёт скорость пальца
        // приглушённой в 5 раз (формула Telegram) — возвращаем настоящие pt/s.
        // Из глубины истории (startedAtBottom == false) не трогаем ничего.
        if finish == .dismiss, startedAtBottom {
            scrollPin.pin(fingerVelocity: initialVelocity * 5) {
                scrolledAwayByHand = false   // финал у дна — якорь автопрокрутки снова цел
            }
        }
    }

    private func completeInteractiveKeyboardAnimation(_ finish: InteractiveKeyboardFinish) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            keyboardDragOffset = finish == .dismiss ? inputBarTravelDistance : 0
            keyboardDragging = false
        }
    }

    // Финал жеста-скрытия: клавиши в этот момент уже за низом экрана (слой увёз
    // мост), поэтому СИСТЕМНАЯ анимация скрытия ничего не покажет — но каждый её
    // кадр гоняет keyboard-layout по всему дереву (грабля с охоты 15.07: layout
    // проходит даже под ignoresSafeArea) прямо поверх живой деселерации ленты —
    // «подфризивает пару секунд». Гасим фокус с ВЫКЛЮЧЕННЫМИ анимациями UIKit:
    // скрытие занимает один кадр — один layout-проход, деселерация течёт чистой.
    private func resignFocusInstantly() {
        endEditingImmediately()
        inputFocused = false   // SwiftUI-зеркало фокуса — вслед за фактом UIKit
    }

    // sendAction(to: nil) иногда попадал не в TextField, а в responder меню выделения,
    // если пользователь успевал снова тапнуть по полю во время финала. endEditing(true)
    // адресует всё окно и гарантированно снимает настоящий UIKit first responder.
    private func endEditingImmediately() {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        UIView.performWithoutAnimation {
            if keyWindow?.endEditing(true) != true {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
            keyWindow?.layoutIfNeeded()
        }
    }

    private func recoverKeyboardFromInterruptedDismiss() {
        // chatReserveCut живёт только между решением «закрыть» и настоящим didHide.
        // Обычный тап по спокойно закрытому или открытому полю сюда не попадает.
        guard chatReserveCut else { return }

        // Отменяем display link старого dismiss, затем закрываем зависшую UIKit-
        // сессию и приводим SwiftUI-зеркала к честному закрытому состоянию.
        keyboardResetGeneration &+= 1
        endEditingImmediately()

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            inputFocused = false
            keyboardHeight = 0
            keyboardDragOffset = 0
            keyboardDragging = false
            chatReserveCut = false
        }

        // didHide от принудительного resign приходит на соседнем run-loop. Даём ему
        // закончить уборку и выдаём полю НОВЫЙ focus — теперь UIKit создаст новую
        // клавиатурную сессию вместо уже активного responder без видимых клавиш.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            inputFocused = true
        }
    }

    private func activateInputFromBubbleTap() {
        // Если тап пришёл в узкое окно незавершённого dismiss, обычного присваивания
        // focus недостаточно: UIKit всё ещё считает TextField первым responder.
        if chatReserveCut {
            recoverKeyboardFromInterruptedDismiss()
        } else if isNearBottom, !chatScrollIsIdle {
            // В нижнем bounce не сталкиваем две пружины. Системный scroll phase сам
            // даст точный момент продолжения — без подобранной на глаз задержки.
            pendingBottomInputFocus = true
        } else {
            inputFocused = true
        }
    }

    // Поспешность панели и чата при выезде клавиатуры. КРУТИТЬ ЗДЕСЬ мелкими шагами:
    // 1.0 — системная длительность; больше — короче и резвее (1.1–1.3 разумный
    // диапазон), меньше 1.0 — ленивее. Форма ниже монотонная, без перелёта/отскока.
    private static let keyboardFollowBoost: Double = 1.3

    private func updateKeyboardFrame(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let height = max(0, UIScreen.main.bounds.intersection(frame).height)
        if height > 0 {
            UserDefaults.standard.set(Double(height), forKey: "naomi.lastKeyboardHeight")
        }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let rawCurve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 3
        let animation: Animation
        switch UIView.AnimationCurve(rawValue: rawCurve) {
        case .easeIn: animation = .easeIn(duration: duration)
        case .easeOut: animation = .easeOut(duration: duration)
        case .linear: animation = .linear(duration: duration)
        default:
            // rawCurve 7 — специальная системная кривая клавиатуры, которую SwiftUI
            // напрямую не принимает. Пружинная аппроксимация давала панели и ленте
            // лишний хвост после того, как клавиши уже остановились. Монотонная cubic
            // быстро подхватывает клавиатуру и мягко приходит РОВНО в 1.0: контрольные
            // точки не выходят за диапазон, поэтому перелёт математически невозможен.
            // Boost теперь меняет только время, а не физику финала.
            animation = .timingCurve(
                0.15, 0.55, 0.25, 1.0,
                duration: max(0.01, duration / Self.keyboardFollowBoost)
            )
        }

        // При полном interactive-dismiss наша независимая панель уже стоит над
        // home indicator, а резерв ленты давно отрезан (chatReserveCut). Выражения-
        // максимумы при нулях дают те же 34/0 — визуально ничего не движется, поэтому
        // обнуляем МГНОВЕННО: анимация здесь лишь полсекунды зря гоняла бы пересборку
        // body поверх дотекающей инерции ленты.
        if height == 0, keyboardDragOffset > 0 {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                keyboardHeight = 0
                keyboardDragOffset = 0
            }
            return
        }

        // Во время своего drag уведомлений обычно нет. Если iOS всё же прислала
        // изменение (например, сменился QuickType), не перебиваем палец анимацией.
        if keyboardDragging {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { keyboardHeight = height }
        } else {
            // Отрезанный жестом резерв возвращаем формуле ДО анимации показа:
            // при закрытой клавиатуре формула тоже даёт 0, снятие бесшовно.
            if chatReserveCut {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) { chatReserveCut = false }
            }
            withAnimation(animation) { keyboardHeight = height }
        }
    }

    // Мягкий подъезд к дну — общий ход для нового ряда и новой строки стрима.
    // Ждём кадр: свежий ряд/строка должны встать в разметку, мгновенный scrollTo
    // целился по СТАРОЙ геометрии — офсет прыгал без анимации (тот самый «телепорт»
    // при отправке и первом ответе). Клавиатура и рост поля сюда не ходят — их ведёт
    // системный якорь sizeChanges (см. bottomAnchoredStart), синхронно с клавиатурой.
    // Повторный зов, пока ждём кадра, схлопывается: прокрутка всё равно поедет
    // к хвосту по самой свежей разметке на момент старта.
    private func nudgeTail(_ proxy: ScrollViewProxy, duration: Double) {
        guard scrollTasks.tailNudge == nil else { return }
        scrollTasks.tailNudge = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            // Перепроверка после кадра: за эти миллисекунды палец мог лечь на ленту
            // и сорвать якорь — тогда не дёргаем (без неё раз в ~секунду стрима
            // случался бы толчок из-под пальца, ровно то, что лечим).
            if !scrolledAwayByHand {
                withAnimation(.easeOut(duration: duration)) {
                    proxy.scrollTo(chatTailID, anchor: .bottom)
                }
            }
            scrollTasks.tailNudge = nil
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

    private var inputChromeLayer: some View {
        GeometryReader { geometry in
            // SwiftUI всё равно меняет нижнюю границу предложения между 898 и
            // 932 pt при финальном keyboard layout. Нормализуем её до физического
            // низа экрана В ЭТОМ ЖЕ layout-проходе, без отдельного @State/event.
            let missingToScreenBottom = max(
                0,
                UIScreen.main.bounds.maxY - geometry.frame(in: .global).maxY
            )
            let physicalClosedClearance = max(
                0,
                deviceBottomSafeArea - missingToScreenBottom
            )
            let keyboardLift = max(
                0,
                inputBarBottomClearance - deviceBottomSafeArea
            )
            // Низ затемнения всегда у физического края экрана. Его верх держим на
            // 29 pt выше центра однострочного ряда: 8 pt нижнего padding + 21 pt
            // половины кнопки «+» + 29 pt захода над центральной линией. Благодаря
            // этому на самой линии центра затемнение уже существенное, а не нулевое.
            // physicalClosedClearance + keyboardLift — фактическое расстояние от
            // низа экрана до нижней границы inputBar в текущем кадре.
            let inputDimmingHeight = physicalClosedClearance + keyboardLift + 58
            // Нижнюю заливку намеренно продолжаем ещё на целую высоту экрана ЗА
            // нижнюю границу текущего layout. Запас находится внутри overlay и не
            // участвует в размере ZStack: иначе высокий слой тени сдвигает нижний
            // якорь самого inputBar за экран.
            let inputDimmingOverscan = UIScreen.main.bounds.height

            ZStack(alignment: .bottom) {
                // Прозрачная коробка задаёт слою только его видимую высоту. Сам
                // рисунок начинается у того же верха, но свободно продолжается
                // вниз под клавиатуру и home indicator, не двигая inputBar.
                Color.clear
                    .frame(height: inputDimmingHeight)
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: theme.inputDimmingStart, location: 0.12),
                                    .init(color: theme.inputDimmingMiddle, location: 0.45),
                                    .init(color: theme.inputDimmingEnd, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 40)

                            theme.inputDimmingEnd
                        }
                        .frame(
                            width: geometry.size.width,
                            height: inputDimmingHeight + inputDimmingOverscan,
                            alignment: .top
                        )
                    }
                    .allowsHitTesting(false)

                inputBar
                    .background {
                        GeometryReader { barGeometry in
                            Color.clear
                                .preference(
                                    key: InputBarHeightPreferenceKey.self,
                                    value: barGeometry.size.height
                                )
                        }
                    }
                    // Постоянный padding участвует в layout только один раз. Ход над
                    // клавиатурой — render-transform: Core Animation интерполирует
                    // его без покадровой переразметки всех сообщений.
                    .padding(.bottom, physicalClosedClearance)
                    .offset(y: -keyboardLift)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // Overlay всегда знает настоящий низ экрана. Только лента продолжает
        // пользоваться штатной keyboard safe area для своей прокрутки.
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

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
                        .foregroundStyle(theme.primaryText)
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
        .padding(.bottom, 8)    // ниже и ближе к клавиатуре/home indicator — как в Telegram
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
            // Пока поле закрыто, верхний прозрачный слой превращает ВСЮ готовую
            // стеклянную капсулу в одну кнопку фокуса. После открытия слой исчезает,
            // поэтому не мешает нативной установке курсора и выделению текста.
            // Во время незавершённого dismiss он остаётся активен и запускает уже
            // существующее восстановление зависшей UIKit-сессии.
            .overlay {
                if !inputFocused || chatReserveCut {
                    Rectangle()
                        .fill(theme.primaryText.opacity(0.001))
                        .contentShape(.interaction, Rectangle())
                        .onTapGesture { activateInputFromBubbleTap() }
                }
            }
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
                    theme.userBubble
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if att.uploaded == nil {
                    theme.uploadingAttachmentOverlay
                }
                if att.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
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
                .foregroundStyle(canSend ? theme.primaryText : theme.secondaryText)
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
            // Живой ход не трогаем: подмена ленты посреди стрима (своего ИЛИ пришедшего из
            // канала) снесла бы растущий пузырь. Слепок на диске уже свежий.
            guard !sending, !liveActive else { return }
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

    // ── Живой канал (/api/events): идущий ход вживую + проактивные сообщения ──
    // Слушаем общую шину сервера постоянно. Свой ход (пока приложение само стримит его через
    // /api/chat) из канала НЕ дублируем — гейт по sending. Всё прочее (ход, запущенный из
    // телеграма/автоматикой, или свой ход после перезахода) рисуем вживую теми же плашками/
    // стримом, а в конце сверяемся с историей — она истина.

    private func startBus() {
        busTask?.cancel()
        busTask = Task { @MainActor in await listenBus() }
    }

    private func listenBus() async {
        while !Task.isCancelled {
            do {
                for try await ev in NaomiAPI.events() {
                    if Task.isCancelled { break }
                    applyBus(ev)
                }
            } catch {
                // обрыв (фон, рестарт сервера, таймаут молчания) — ниже пауза и заново
            }
            if Task.isCancelled { break }
            await NaomiAPI.reroute()   // дорога могла умереть — перевыбрать (дом приоритетен)
            try? await Task.sleep(for: .seconds(2))   // не долбим сервер, пока недоступен
        }
    }

    private func applyBus(_ ev: NaomiAPI.BusEvent) {
        // Свой ход рисует /api/chat-стрим — его эхо из канала не дублируем.
        guard !sending else { return }
        switch ev.type {
        case "live":     applyLive(ev)
        case "incoming": applyIncoming(ev)
        default:         break   // orders_badge, tg_live (телеграм-зеркало веба) — не наши
        }
    }

    private func applyLive(_ ev: NaomiAPI.BusEvent) {
        switch ev.ev {
        case "start":
            liveBegin(seed: [])
        case "catchup":
            liveBegin(seed: ev.segs.map { NaomiAPI.liveRows(fromSegments: $0) } ?? [])
        case "delta":
            if let d = ev.d { liveDelta(d) }
        case "action":
            liveAction(ActionLabels.label(name: ev.name ?? "", sub: ev.sub == 1))
        case "tool":
            liveAction(ActionLabels.label(name: "WebSearch", q: ev.q, sub: ev.sub == 1))
        case "break":
            liveCloseText()
        case "file":
            if let rel = ev.name, !rel.isEmpty { liveFile(rel) }
        case "end":
            liveEndTurn()
        default:
            break   // silent/error — финал end покажет истину
        }
    }

    // Начать/пересобрать живой ход. seed — ряды догоняющего буфера (catchup) или пусто (start).
    private func liveBegin(seed: [ChatMessage]) {
        liveReset()
        liveActive = true
        for row in seed {
            messages.append(row)
            liveRowIDs.append(row.id)
        }
        // Хвост буфера продолжаем вживую: текст — дописываем дельтами, плашку — оживляем волной.
        if let last = messages.last, liveRowIDs.contains(last.id),
           let i = messages.firstIndex(where: { $0.id == last.id }) {
            if messages[i].kind == .action { messages[i].isLive = true; liveChipID = last.id }
            else if messages[i].kind == .text { messages[i].isStreaming = true; liveReplyID = last.id }
        }
    }

    // Убрать ряды текущего живого хода (обрыв/пересборка). Свой поток и историю не трогает.
    private func liveReset() {
        if !liveRowIDs.isEmpty {
            let ids = Set(liveRowIDs)
            messages.removeAll { ids.contains($0.id) }
        }
        liveRowIDs = []
        liveChipID = nil
        liveReplyID = nil
        liveActive = false
    }

    private func liveDelta(_ piece: String) {
        liveActive = true
        if let cid = liveChipID, let i = messages.firstIndex(where: { $0.id == cid }) {
            messages[i].isLive = false   // пошёл текст — живая плашка застыла
        }
        liveChipID = nil
        if let rid = liveReplyID, let i = messages.firstIndex(where: { $0.id == rid }) {
            messages[i].text += piece
        } else {
            let clean = String(piece.drop(while: { $0.isNewline }))   // ведущий разделитель слоя гасим
            guard !clean.isEmpty else { return }
            var reply = ChatMessage(role: .assistant, text: clean, kind: .text)
            reply.isStreaming = true
            messages.append(reply)
            liveReplyID = reply.id
            liveRowIDs.append(reply.id)
        }
    }

    private func liveAction(_ label: String) {
        liveActive = true
        liveCloseText()
        if let cid = liveChipID, let i = messages.firstIndex(where: { $0.id == cid }) {
            withAnimation(.easeInOut(duration: 0.2)) { messages[i].text = label }   // та же плашка перетекает
        } else {
            var chip = ChatMessage(role: .assistant, text: label, kind: .action)
            chip.isLive = true
            messages.append(chip)
            liveChipID = chip.id
            liveRowIDs.append(chip.id)
        }
    }

    private func liveCloseText() {
        guard let rid = liveReplyID, let i = messages.firstIndex(where: { $0.id == rid }) else { liveReplyID = nil; return }
        if messages[i].text.isEmpty && messages[i].files.isEmpty {
            messages.remove(at: i)
            liveRowIDs.removeAll { $0 == rid }
        } else {
            messages[i].isStreaming = false
        }
        liveReplyID = nil
    }

    private func liveFile(_ rel: String) {
        liveActive = true
        liveCloseText()
        if let cid = liveChipID, let i = messages.firstIndex(where: { $0.id == cid }) {
            messages[i].isLive = false
        }
        liveChipID = nil
        var m = ChatMessage(role: .assistant, text: "")
        m.files = [rel]
        messages.append(m)
        liveRowIDs.append(m.id)
    }

    // Ход из канала закончился: застудить плашку/текст и подменить живые ряды сохранённым
    // ходом из истории (сегменты, файлы, финальный текст) — она истина.
    private func liveEndTurn() {
        if let cid = liveChipID, let i = messages.firstIndex(where: { $0.id == cid }) { messages[i].isLive = false }
        if let rid = liveReplyID, let i = messages.firstIndex(where: { $0.id == rid }) { messages[i].isStreaming = false }
        liveActive = false
        liveChipID = nil
        liveReplyID = nil
        liveRowIDs = []
        Task { await loadHistory() }
    }

    // Проактивное сообщение вне живого хода (автоматика, напоминалка, зеркало телеграма).
    private func applyIncoming(_ ev: NaomiAPI.BusEvent) {
        let text = ev.content ?? ""
        let files = ev.files ?? []
        guard text != "[тихо]", !(text.isEmpty && files.isEmpty) else { return }   // тихий ход не рисуем
        var msg = ChatMessage(role: ev.role == "user" ? .user : .assistant, text: text)
        msg.files = files
        messages.append(msg)
        ChatCache.save(messages)
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
        leftForegroundMidSend = false   // новый ход — прошлый «свернули» не в счёт
        // Отправка перевзводит якорь: свой ход везёт чат вниз из любой глубины
        // переписки (guard на новые ряды теперь смотрит только на якорь, не на sending).
        scrolledAwayByHand = false
        scrollPin.cancel()   // отправка сама везёт к дну — возврат-пружине тут делать нечего
        // Окно ленты — обратно к базе: после чтения старой переписки оно разрастается
        // (по +80 за подгрузку) и НЕ сжимается само, а большое окно возвращает тяжёлый
        // покадровый пересчёт при движении клавиатуры. Отправка и так везёт чат на дно,
        // где сжатие не видно: последние windowBase рядов — те же самые пиксели.
        if windowCount != Self.windowBase { windowCount = Self.windowBase }
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
            // Держим сетевой ход живым ещё немного, если Слава свернёт приложение прямо
            // во время ответа: короткий ответ успевает дойти целиком, без обрыва. Дольше
            // (~30 с) iOS фон не даёт — тогда ход доигрывается на Маке, а телефон заберёт
            // его из истории при возврате (см. leftForegroundMidSend в конце хода).
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "naomi-chat") {
                UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
            }
            defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }
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
                // Обрыв из-за сворачивания приложения — НЕ «не дозвонилась»: Мак на месте
                // и дописывает ответ сам, заберём его из истории в конце хода. Ложную
                // ошибку показываем только при настоящем обрыве (Мак спит / не тот Wi-Fi),
                // когда приложение всё это время оставалось на переднем плане.
                if !leftForegroundMidSend {
                    fail("Не дозвонилась до Наоми. Проверь Wi-Fi и что Мак не спит.")
                }
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
            // Прервались сворачиванием — забираем с Мака то, что он дописал, пока телефон
            // был заморожен: оборванный на полуслове живой кусок сменяется готовым ответом.
            if leftForegroundMidSend {
                await loadHistory()
            }
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
private struct InputGlassBackgroundModifier: ViewModifier {
    @Environment(\.naomiTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(theme.inputGlassTint),
                in: RoundedRectangle(cornerRadius: 22)
            )
        } else {
            content.background(theme.userBubble, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

private struct SendGlassBackgroundModifier: ViewModifier {
    @Environment(\.naomiTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(theme.buttonGlassTint).interactive(),
                in: Circle()
            )
        } else {
            content.background(theme.userBubble, in: Circle())
        }
    }
}

private struct TitleGlassBackgroundModifier: ViewModifier {
    @Environment(\.naomiTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(theme.titleGlassTint).interactive(),
                in: Capsule()
            )
        } else {
            content.background(theme.userBubble, in: Capsule())
        }
    }
}

private extension View {
    // Фон поля ввода: родное «жидкое стекло» iOS 26 — ровно тот же эффект,
    // что у системных кнопок в шапке (шестерёнки), поле не выделяется из
    // общего стиля. На старых iOS — прежний матовый пузырь.
    func inputGlassBackground() -> some View {
        modifier(InputGlassBackgroundModifier())
    }

    // Кнопка отправки — то же стекло, круглая; interactive даёт родной отклик
    // на нажатие (блик и продавливание, как у системных стеклянных кнопок).
    func sendGlassBackground() -> some View {
        modifier(SendGlassBackgroundModifier())
    }

    // Дно ленты — системному якорю, двумя ролями (iOS 18+):
    // • initialOffset — первая разметка встаёт к низу истории;
    // • sizeChanges — при смене РАЗМЕРА вьюпорта (клавиатура выезжает/сворачивается,
    //   поле ввода растёт строкой) офсет корректируется в том же layout-проходе и тем
    //   же ходом, что сама клавиатура — чат едет с ней 1-в-1, синхронно. Раньше это
    //   делал свой scrollTo по нотификации клавиатуры: своя кривая + задержка = чат
    //   «догонял» клавиатуру, а после пружины у дна scrollTo попадал в живую инерцию
    //   и промахивался — клавиатура выезжала, лента оставалась на месте.
    // Якорь sizeChanges сохраняет ВИДИМУЮ точку (низ экрана остаётся тем же низом):
    // читаешь старую переписку — клавиатура ничего не утаскивает на дно чата.
    // Исключение — ЖИВАЯ пружина у дна в момент тапа: её инерция ведёт офсет к старому
    // дну и перебивает коррекцию якоря; этот случай ловит onChange(inputFocused).
    // Рост КОНТЕНТА (стрим, новые ряды) — это не размер контейнера: его по-прежнему
    // ведёт nudgeTail анимированной прокруткой, телепорт строк якорь не возвращает.
    @ViewBuilder
    func bottomAnchoredStart() -> some View {
        if #available(iOS 18.0, *) {
            self
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }

    // Только резервирует место под независимую панель; снизу намеренно нет отдельной
    // тени, material или scroll-edge blur — видны лишь стеклянные контролы inputBar.
    @ViewBuilder
    func floatingBottomReserve(height: CGFloat) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }

    // Шапка тем же механизмом, что поле ввода: safeAreaBar сверху + родное
    // прогрессивное затемнение края при заезде ленты под бар (системный навбар
    // спрятан — с пустым титулом iOS такого затемнения не рисовала вовсе).
    @ViewBuilder
    func floatingHeaderBar<Bar: View>(@ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            self
                .safeAreaBar(edge: .top, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }

    // «Облачко» надписи в шапке — стеклянная капсула, как у кнопок ниже; interactive
    // даёт родной отклик на нажатие (облачко — кнопка настроек). Фолбэк — матовый пузырь.
    func titleGlassBackground() -> some View {
        modifier(TitleGlassBackgroundModifier())
    }

    // Датчики прокрутки — общий порог «у дна» 150 пт.
    // • nearBottom: доехал ли до дна (перелёт пружины за дно — тоже «у дна»). Нужен
    //   тапу в поле ввода: факт «дошёл до конца» помнится, даже пока лента отскакивает.
    // • handScrolled — якорь автопрокрутки стрима: палец (.tracking/.interacting)
    //   срывает его МГНОВЕННО — стрим не смеет дёргать чат из-под руки; обратно якорь
    //   цепляется, когда движение УЛЕГЛОСЬ у дна (.idle) — не раньше: перевзвод по
    //   простому «пролетаю мимо дна» случался прямо под пальцем. Отпустил выше дна —
    //   чат стоит, где оставил, пока сам не спустится.
    // На старых iOS не отслеживаем: якорь вечно цел, дно вечно «рядом» — как раньше.
    @ViewBuilder
    func trackScroll(nearBottom: Binding<Bool>, handScrolled: Binding<Bool>,
                     keyboardDragging: Binding<Bool>, isIdle: Binding<Bool>) -> some View {
        if #available(iOS 18.0, *) {
            self
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.visibleRect.maxY >= geo.contentSize.height - 150
                } action: { _, isNear in
                    nearBottom.wrappedValue = isNear
                }
                .onScrollPhaseChange { _, newPhase, context in
                    isIdle.wrappedValue = newPhase == .idle
                    // Жест окна и ScrollView начинают одновременно. Пока Telegram-
                    // жест ведёт клавиатуру, не даём его служебным фазам сорвать
                    // автопрокруточный якорь стрима.
                    guard !keyboardDragging.wrappedValue else { return }
                    if newPhase == .tracking || newPhase == .interacting {
                        handScrolled.wrappedValue = true
                    } else if newPhase == .idle {
                        let geo = context.geometry
                        if geo.visibleRect.maxY >= geo.contentSize.height - 150 {
                            handScrolled.wrappedValue = false
                        }
                    }
                }
        } else {
            self
        }
    }

    // Живое расстояние до дна — зеркалом в коробку возврата (ChatScrollPinBox), мимо
    // @State: пишется каждым кадром прокрутки, перерисовок не дёргает. Нужно мосту
    // клавиатурного жеста в момент КАСАНИЯ («началось ли оно у дна») — булевы состояния
    // с порогом 150 для этого слишком грубы. Старые iOS — без датчика: в коробке
    // остаётся «бесконечно далеко», и возврат к дну просто не включается.
    @ViewBuilder
    func trackBottomDistance(into box: ChatScrollPinBox) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - geo.visibleRect.maxY
            } action: { _, distance in
                box.distanceToBottom = distance
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
    @Environment(\.naomiTheme) private var theme
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
                    .foregroundStyle(theme.completedActionText)
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
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 18))
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
                    .foregroundStyle(message.isError ? theme.errorText : theme.primaryText)
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

// Бегущая светлая волна — «фонарик», сигнал «Наоми делает это прямо сейчас в фоне».
// Аналог sp-shimmer из веба (styles.css), тот же период 2.2 с. Волна — градиентная
// полоса поверх текста, обрезанная маской по его же глифам; TimelineView двигает её
// покадрово (withAnimation тут не годится: repeatForever не пересчитал бы ход при
// смене подписи, а contentTransition-морф текста живёт своей жизнью под волной).
// Общая для плашек дел в ленте и надписи «Наоми» в шапке (когда она думает).
private struct NaomiShimmerModifier: ViewModifier {
    @Environment(\.naomiTheme) private var theme
    let period: Double
    let minBand: CGFloat
    let peak: Double

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation) { context in
                GeometryReader { geo in
                    let phase = (context.date.timeIntervalSinceReferenceDate / period)
                        .truncatingRemainder(dividingBy: 1)
                    let band = max(geo.size.width * 0.45, minBand)   // ширина «луча»
                    LinearGradient(
                        colors: [.clear, theme.primaryText.opacity(peak), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: -band + (geo.size.width + band) * phase)
                }
            }
            .mask(content)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    // По умолчанию — пресет плашек дел (период 2.2 с, мягкий луч с минимумом 36 пт).
    // Шапка зовёт со своими: короткому слову «Наоми» луч в 36 пт — почти во всю
    // ширину, «бега» не видно, поэтому там луч уже, ярче и период короче.
    func naomiShimmer(period: Double = 2.2, minBand: CGFloat = 36,
                      peak: Double = 0.85) -> some View {
        modifier(NaomiShimmerModifier(period: period, minBand: minBand, peak: peak))
    }
}

// Волна по условию — для надписи «Наоми» в шапке. Отдельный модификатор, а не
// if в месте употребления, чтобы в покое не оставался TimelineView(.animation):
// он гонит кадры без остановки, в тихой шапке ему делать нечего.
struct ShimmerIf: ViewModifier {
    let active: Bool
    var period: Double = 2.2
    var minBand: CGFloat = 36
    var peak: Double = 0.85

    func body(content: Content) -> some View {
        if active {
            content.naomiShimmer(period: period, minBand: minBand, peak: peak)
        } else {
            content
        }
    }
}

// Живая подпись дела: приглушённый текст плашки + волна поверх.
private struct ShimmerText: View {
    @Environment(\.naomiTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: naomiChipFontSize))
            .foregroundStyle(theme.secondaryText)
            .contentTransition(.opacity)
            .naomiShimmer()
    }
}

// Три точки «Наоми думает»: бегущая волна прозрачности.
struct TypingDots: View {
    @Environment(\.naomiTheme) private var theme
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(theme.secondaryText)
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

#Preview("Чат без сети") {
    ChatView(previewMode: true)
}
