// Палитра — один в один с вебом (frontend/styles.css): тёплая «бумага» + терракотовый акцент.
import SwiftUI

extension Color {
    /// Цвет с раздельными значениями для светлой и тёмной темы.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }

    static let naomiBg = Color(light: 0xFAF9F6, dark: 0x16150F)
    static let naomiBubble = Color(light: 0xEFEAE0, dark: 0x2A281F)
    static let naomiAccent = Color(light: 0xC96442, dark: 0xE08562)
}

// Шрифты чата (15.07) — КРУТИТЬ ЗДЕСЬ. Пропорции сняты с веба, где размеры подобраны
// и нравятся Славе: текст 15.5, плашка 13.5 (плашка ≈ 0.87 от текста). Масштабируем
// на айфон под текст 18.
let naomiChatFontSize: CGFloat = 18     // текст переписки (веб asst-body 15.5)
let naomiChipFontSize: CGFloat = 15.5   // плашка «что делаю» (веб act-layer 13.5 → та же доля от текста)
