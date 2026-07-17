// Настройки: две дороги к Наоми — по дому (имя Мака в сети) и из мира (туннель).
// Приложение выбирает дорогу само (NaomiAPI.reroute), тут только адреса и пропуск.
// Открываются по тапу на облачко «Наоми» в шапке чата; onSave зовёт чат после «Готово».
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.naomiTheme) private var theme
    @AppStorage("serverLocal") private var serverLocal = NaomiAPI.defaultLocal
    @AppStorage("serverTunnel") private var serverTunnel = ""
    @AppStorage("apiToken") private var apiToken = ""
    var onSave: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://имя-мака.local:8787", text: $serverLocal)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Дорога по дому")
                } footer: {
                    Text("Имя Мака в домашней сети (macOS: Настройки → Основные → Общий доступ). Живёт даже без интернета и не ломается, когда роутер после перезагрузки раздаёт новые адреса.")
                }

                Section {
                    TextField("https://адрес-туннеля", text: $serverTunnel)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Дорога из мира")
                } footer: {
                    Text("Туннель Cloudflare. Приложение сначала стучится по дому; дверь молчит — молча уходит сюда. Для этой дороги нужен пропуск ниже.")
                }

                Section {
                    SecureField("токен из backend/.env", text: $apiToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Пропуск")
                } footer: {
                    Text("Значение NAOMI_API_TOKEN из backend/.env на Маке. Дома по Wi-Fi не нужен, через туннель — обязателен.")
                }

                Section {
                    Button("Вернуть домашний адрес") {
                        serverLocal = NaomiAPI.defaultLocal
                    }
                    .tint(theme.accent)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                        onSave()
                    }
                    .tint(theme.accent)
                }
            }
        }
    }
}
