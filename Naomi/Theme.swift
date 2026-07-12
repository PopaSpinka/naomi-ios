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
