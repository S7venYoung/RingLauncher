import SwiftUI

struct RingMenuView: View {
    @State private var selectedIndex: Int = 0
    @State private var scrollBuffer: CGFloat = 0
    
    let items = [
        ActionItem(title: "复制", icon: "doc.on.doc") { print("Copying...") },
        ActionItem(title: "粘贴", icon: "doc.on.clipboard") { print("Pasting...") },
        ActionItem(title: "截图", icon: "camera") { print("Screenshot...") },
        ActionItem(title: "搜索", icon: "magnifyingglass") { print("Searching...") },
        ActionItem(title: "终端", icon: "terminal") { print("Terminal...") }
    ]
    
    let radius: CGFloat = 110

    var body: some View {
        ZStack {
            // 背景磨砂圆环
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 80, height: 80)
            
            ForEach(0..<items.count, id: \.self) { index in
                let angle = Double(index) / Double(items.count) * 2 * .pi - .pi / 2
                let isSelected = index == selectedIndex
                
                VStack(spacing: 8) {
                    Image(systemName: items[index].icon)
                        .font(.system(size: isSelected ? 28 : 20, weight: .medium))
                    if isSelected {
                        Text(items[index].title)
                            .font(.caption2).bold()
                            .transition(.opacity)
                    }
                }
                .foregroundColor(isSelected ? .blue : .primary)
                .scaleEffect(isSelected ? 1.3 : 1.0)
                .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selectedIndex)
            }
        }
        .frame(width: 400, height: 400)
        .background(ScrollHandler { delta in
            handleScroll(delta)
        })
    }

    private func handleScroll(_ delta: CGFloat) {
        scrollBuffer += delta
        if abs(scrollBuffer) > 15 { // 灵敏度阈值
            if scrollBuffer > 0 {
                selectedIndex = (selectedIndex + 1) % items.count
            } else {
                selectedIndex = (selectedIndex - 1 + items.count) % items.count
            }
            scrollBuffer = 0
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}

// 辅助组件：截获滚轮事件
struct ScrollHandler: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { ScrollViewHelper(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class ScrollViewHelper: NSView {
    var onScroll: (CGFloat) -> Void
    init(onScroll: @escaping (CGFloat) -> Void) {
        self.onScroll = onScroll
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func scrollWheel(with event: NSEvent) { onScroll(event.scrollingDeltaY) }
}