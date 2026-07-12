// Наоми для iOS — нативный клиент к домашнему серверу (backend/server.js).
// Приложение — ещё одна «вкладка» рядом с вебом и телеграмом: та же история, тот же мозг.
import SwiftUI

@main
struct NaomiApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
