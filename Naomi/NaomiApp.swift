// Наоми для iOS — нативный клиент к домашнему серверу (backend/server.js).
// Приложение — ещё одна «вкладка» рядом с вебом и телеграмом: та же история, тот же мозг.
// Всё приложение — один экран чата; настройки подключения — по тапу на облачко «Наоми».
import SwiftUI

@main
struct NaomiApp: App {
    // Старые настройки хранили один адрес сервера — раскладываем по двум дорогам
    // (дом/туннель) до первого запроса, см. NaomiAPI.migrateSettings.
    init() { NaomiAPI.migrateSettings() }

    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
