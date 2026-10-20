import SwiftUI

/// The window's background photo, darkened so light text stays readable (same as 007 Talk).
struct AppBackground: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "background", withExtension: "jpg")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        ZStack {
            Color.black
            if let img = Self.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.15), .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }
}

struct Avatar: View {
    @EnvironmentObject var store: NoteStore
    let name: String
    let url: URL?
    var size: CGFloat = 28
    @State private var image: NSImage?

    private var initials: String {
        let s = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Color(red: 0.36, green: 0.52, blue: 0.80))
                Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            guard let url, let api = store.api else { return }
            image = await store.images.image(url, api: api)
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.10)))
    }
}

/// WhatsApp-style ticks: ✓ saved on this Mac, ✓✓ (blue) on the server.
struct StatusTicks: View {
    let status: NoteStatus
    var size: CGFloat = 11

    var body: some View {
        switch status {
        case .synced:
            HStack(spacing: -size * 0.45) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: size, weight: .bold))
            .foregroundColor(Theme.syncedBlue)
        case .pending:
            Image(systemName: "checkmark")
                .font(.system(size: size, weight: .bold))
                .foregroundColor(.secondary)
        case .syncing:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size))
                .foregroundColor(.orange)
        }
    }
}
