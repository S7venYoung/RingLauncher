import SwiftUI

struct RingMenuView: View {
    @State private var selectedIndex: Int = 0
    @State private var scrollAmount: CGFloat = 0
    let items = ["复制", "粘贴", "截图", "搜索", "终端"]
    
    let ringRadius: Double = 120 // 改为 Double 减少转换歧义
    let panelSize: CGFloat = 400

    var body: some View {
        ZStack {
            // 中心圆环背景
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 100, height: 100)
                .overlay(Text(items[selectedIndex]).bold())

            ForEach(0..<items.count, id: \.self) { i in
                let isSelected = (i == selectedIndex)
                let pos = calculatePosition(for: i)
                
                VStack {
                    Image(systemName: "star.fill")
                        .foregroundColor(isSelected ? .blue : .gray)
                        .font(.system(size: isSelected ? 30 : 20))
                }
                .scaleEffect(isSelected ? 1.5 : 1.0)
                .offset(x: pos.x, y: pos.y)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selectedIndex)
            }
        }
        .frame(width: panelSize, height: panelSize)
        .background(ScrollDetector { delta in
            handleScroll(delta: delta)
        })
    }

    // 修复歧义：明确使用 Double 类型进行三角函数运算
    private func calculatePosition(for index: Int) -> CGPoint {
        let total = Double(items.count)
        let angle: Double = (Double(index) / total * 2.0 * .pi) - (.pi / 2.0)
        // 显式转换为 CGFloat 以兼容 CGPoint
        return CGPoint(x: CGFloat(cos(angle) * ringRadius), 
                       y: CGFloat(sin(angle) * ringRadius))
    }

    private func handleScroll(delta: CGFloat) {
        scrollAmount += delta
        if abs(scrollAmount) > 10 {
            selectedIndex = (selectedIndex + (scrollAmount > 0 ? 1 : -1) + items.count) % items.count
            scrollAmount = 0
            // 现在 WindowManager 有这个成员了，不会再报错
            WindowManager.shared.currentSelection = items[selectedIndex]
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}

// 滚轮辅助组件保持不变
struct ScrollDetector: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { ScrollViewHelper(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class ScrollViewHelper: NSView {
    var onScroll: (CGFloat) -> Void
    init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func scrollWheel(with event: NSEvent) { onScroll(event.scrollingDeltaY) }
}
