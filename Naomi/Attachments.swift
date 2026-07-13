// Фото в чате: миниатюры в сообщениях (мои и Наоми), полноэкранный просмотр по тапу.
// Картинки живут на складе сервера и тянутся через /api/file/<путь> с пропуском —
// AsyncImage не умеет заголовки, поэтому свой лёгкий загрузчик с кэшем в памяти.
import SwiftUI

// Что считать картинкой — то же правило, что в вебе (IS_IMG_RE).
func isImageFile(_ rel: String) -> Bool {
    let ext = (rel as NSString).pathExtension.lowercased()
    return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext)
}

// ── Миниатюра со склада ──

struct RemoteImage: View {
    let rel: String

    @State private var image: UIImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, UIImage>()
    // Семя кэша: только что выбранное фото уже на руках — не тянуть его назад по сети.
    static func seed(rel: String, image: UIImage) {
        cache.setObject(image, forKey: rel as NSString)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.naomiBubble
                    if failed {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task(id: rel) {
            if let cached = Self.cache.object(forKey: rel as NSString) {
                image = cached
                return
            }
            do {
                let img = try await NaomiAPI.loadImage(rel: rel, maxPixel: 700)
                Self.cache.setObject(img, forKey: rel as NSString)
                image = img
            } catch {
                failed = true
            }
        }
    }
}

// ── Ряд вложений одного сообщения ──

struct MsgAttachments: View {
    let files: [String]
    var onTapImage: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(files, id: \.self) { rel in
                if isImageFile(rel) {
                    Button { onTapImage(rel) } label: {
                        RemoteImage(rel: rel)
                            // одно фото — покрупнее, несколько — плиткой
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Не картинка (документ и т.п.) — чип с именем, без открытия.
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text((rel as NSString).lastPathComponent)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.naomiBubble.opacity(0.55), in: Capsule())
                }
            }
        }
    }

    private var side: CGFloat { files.count == 1 ? 200 : 124 }
}

// ── Полноэкранный просмотр ──

struct LightboxItem: Identifiable {
    let rel: String
    var id: String { rel }
}

struct LightboxView: View {
    let rel: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                    Text("Не загрузилось")
                }
                .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onTapGesture { dismiss() }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .padding(16)
        }
        .task {
            // Полный размер под экран телефона; миниатюрный кэш не трогаем.
            do { image = try await NaomiAPI.loadImage(rel: rel, maxPixel: 2400) }
            catch { failed = true }
        }
    }
}
