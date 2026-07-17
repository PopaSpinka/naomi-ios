// Все цвета и их прозрачность редактируются штатно в Assets.xcassets.
// Выбери нужный Color Set, затем светлый/тёмный образец и открой цветной квадрат
// в Attributes inspector. Canvas подхватывает сохранённое значение автоматически.
import SwiftUI

struct NaomiTheme {
    // Основные поверхности и текст.
    var background: Color
    var userBubble: Color
    var accent: Color
    var primaryText: Color
    var secondaryText: Color
    var warning: Color

    // Тонировка системного Liquid Glass. Alpha 0 = чистое системное стекло.
    var inputGlassTint: Color
    var buttonGlassTint: Color
    var titleGlassTint: Color

    // Три самостоятельных Color Set уже содержат нужную прозрачность градиента.
    var inputDimmingStart: Color
    var inputDimmingMiddle: Color
    var inputDimmingEnd: Color

    // Цвет + alpha заметных состояний также целиком живут в Assets.
    var completedActionText: Color
    var errorText: Color
    var attachmentChip: Color
    var uploadingAttachmentOverlay: Color

    // Здесь только связи «элемент интерфейса → именованный Color Set».
    static let standard = NaomiTheme(
        background: Color("ChatBackground"),
        userBubble: Color("UserBubble"),
        accent: Color("AccentColor"),
        primaryText: Color("PrimaryText"),
        secondaryText: Color("SecondaryText"),
        warning: Color("Warning"),
        inputGlassTint: Color("InputGlassTint"),
        buttonGlassTint: Color("ButtonGlassTint"),
        titleGlassTint: Color("TitleGlassTint"),
        inputDimmingStart: Color("InputDimmingStart"),
        inputDimmingMiddle: Color("InputDimmingMiddle"),
        inputDimmingEnd: Color("InputDimmingEnd"),
        completedActionText: Color("CompletedActionText"),
        errorText: Color("ErrorText"),
        attachmentChip: Color("AttachmentChip"),
        uploadingAttachmentOverlay: Color("UploadingAttachmentOverlay")
    )
}

private struct NaomiThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = NaomiTheme.standard
}

extension EnvironmentValues {
    var naomiTheme: NaomiTheme {
        get { self[NaomiThemeEnvironmentKey.self] }
        set { self[NaomiThemeEnvironmentKey.self] = newValue }
    }
}

// Шрифты чата (15.07) — КРУТИТЬ ЗДЕСЬ. Пропорции сняты с веба, где размеры подобраны
// и нравятся Славе: текст 15.5, плашка 13.5 (плашка ≈ 0.87 от текста). Масштабируем
// на айфон под текст 18.
let naomiChatFontSize: CGFloat = 18     // текст переписки (веб asst-body 15.5)
let naomiChipFontSize: CGFloat = 15.5   // плашка «что делаю» (веб act-layer 13.5 → та же доля от текста)
