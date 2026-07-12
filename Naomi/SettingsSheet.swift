// Настройки: адрес сервера Наоми. Пригодится, когда появится Tailscale
// или сервер переедет — без пересборки приложения.
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverURL") private var serverURL = NaomiAPI.defaultBase
    var onSave: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://адрес:8787", text: $serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Адрес сервера")
                } footer: {
                    Text("Наоми живёт на Маке, приложение ходит к нему по домашнему Wi-Fi. Адрес — это имя Мака в сети: http://имя-мака.local:8787 (имя видно в macOS: Настройки → Основные → Общий доступ).")
                }

                Section {
                    Button("Вернуть стандартный адрес") {
                        serverURL = NaomiAPI.defaultBase
                    }
                    .tint(.naomiAccent)
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
                    .tint(.naomiAccent)
                }
            }
        }
    }
}
