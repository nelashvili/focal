import SwiftUI

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    var onPick: (Int) -> Void

    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(model.cardWidth), spacing: 12), count: model.columns)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { i, w in
                        WindowCard(window: w, thumb: model.thumbs[w.id], showThumbnail: model.showThumbnails,
                                   width: model.cardWidth, selected: i == model.selected)
                            .id(i)
                            .onTapGesture { onPick(i) }
                    }
                }
                .padding(16)
            }
            .onChange(of: model.selected) { _, new in proxy.scrollTo(new) }
        }
    }
}

private struct WindowCard: View {
    let window: WindowInfo
    let thumb: NSImage?
    let showThumbnail: Bool
    let width: CGFloat
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18))
                if showThumbnail, let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).padding(2)
                } else if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56).opacity(0.9)
                }
            }
            .frame(width: width - 16, height: SwitcherController.thumbHeight(width))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if window.isMinimized { Badge(text: "Minimized") }
                    if window.isAppHidden { Badge(text: "Hidden") }
                }.padding(5)
            }

            HStack(spacing: 6) {
                if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(window.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
        }
        .padding(8)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Color(nsColor: .controlAccentColor) : .clear, lineWidth: 3))
        .contentShape(Rectangle())
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .foregroundStyle(.white)
    }
}
