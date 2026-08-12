import SwiftUI
import AppKit

/// 切换会话的展示模型（仅在主线程读写）：瓦片 + 选中下标
final class WindowSwitcherViewModel: ObservableObject {
    @Published var tiles: [SwitcherWindow] = []
    @Published var selectedIndex = 0

    var selectedWindow: SwitcherWindow? {
        guard selectedIndex >= 0, selectedIndex < tiles.count else { return nil }
        return tiles[selectedIndex]
    }
}

/// 单个窗口卡：缩略图（未就绪显示 app 图标占位）+ 标题 + app 名；
/// 悬停时左上角显示操作按钮（退出/关闭/最小化/全屏）。
struct SwitcherTileView: View {
    let tile: SwitcherWindow
    let isSelected: Bool
    let isHovered: Bool
    var onSelect: () -> Void
    var onAction: (WindowOperation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(isHovered && !isSelected ? 0.10 : 0))
                if let thumbnail = tile.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else if let icon = tile.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 52, maxHeight: 52)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }

                if isHovered {
                    HStack(spacing: 4) {
                        if tile.isWindowlessApp {
                            TileActionButton(symbol: "power", title: "退出应用", fill: .purple) { onAction(.quitApp) }
                        } else {
                            TileActionButton(symbol: "power", title: "退出应用", fill: .purple) { onAction(.quitApp) }
                            TileActionButton(symbol: "xmark", title: "关闭窗口", fill: .red) { onAction(.close) }
                            TileActionButton(symbol: "minus", title: "最小化", fill: .yellow, symbolColor: .black) { onAction(.minimize) }
                            TileActionButton(symbol: "arrow.up.left.and.arrow.down.right", title: "全屏切换", fill: .green) { onAction(.maximize) }
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(5)
                }
            }
            .frame(width: 168, height: 118)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 3 : 1)
            )
            .scaleEffect(isSelected ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isSelected)

            Text(tile.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 168, alignment: .leading)
                .foregroundColor(.primary)
                .padding(.top, 4)
            Text(tile.appName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 168, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// 缩略图左上角的圆形操作按钮（系统红绿灯样式：直径 12pt，退出紫 / 关闭红 / 最小化黄 / 全屏绿）
private struct TileActionButton: View {
    let symbol: String
    let title: String
    let fill: Color
    var symbolColor: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(symbolColor)
                .frame(width: 12, height: 12)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// 切换器每行列数上限（面板布局与 CommandTabSwitcher 的方向键上下移动共用）
let switcherColumns = 6

/// 瓦片网格：每行最多 6 个，宽度随窗口数量自适应（不足 6 个时更窄），不满的行内容居中。
/// 悬停高亮、点击即切换；窗口多时整网格纵向滚动。
struct WindowSwitcherGridView: View {
    @ObservedObject var model: WindowSwitcherViewModel
    var onSelect: (CGWindowID) -> Void
    var onAction: (CGWindowID, WindowOperation) -> Void
    @State private var hoveredID: CGWindowID?

    private static let cardWidth: CGFloat = 168
    private static let spacing: CGFloat = 12

    /// 把瓦片切成每行 ≤ switcherColumns 的行（行序稳定、块内保序）
    private var rows: [[SwitcherWindow]] {
        let tiles = model.tiles
        guard !tiles.isEmpty else { return [] }
        return stride(from: 0, to: tiles.count, by: switcherColumns).map { start in
            Array(tiles[start..<min(start + switcherColumns, tiles.count)])
        }
    }

    /// 宽 = 列数×卡宽 + (列数-1)×间距 + 两侧 padding(14×2)；不足 6 个时按实际列数收窄
    private var gridWidth: CGFloat {
        let columns = max(1, min(model.tiles.count, switcherColumns))
        return CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * Self.spacing + 28
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Self.spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { colIndex, tile in
                            let globalIndex = rowIndex * switcherColumns + colIndex
                            SwitcherTileView(
                                tile: tile,
                                isSelected: globalIndex == model.selectedIndex,
                                isHovered: hoveredID == tile.id,
                                onSelect: { onSelect(tile.id) },
                                onAction: { onAction(tile.id, $0) }
                            )
                            .onHover { hovering in
                                hoveredID = hovering ? tile.id : nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .frame(width: gridWidth, alignment: .center)
        }
        .frame(maxWidth: gridWidth)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
        .padding(10)
    }
}

/// 切换面板窗口：非激活 borderless 面板，配置与截图遮罩窗口一致。
/// 键盘由 CommandTabSwitcher 的事件 tap 处理（canBecomeKey=false）；
/// 鼠标悬停/点击走 SwiftUI 手势。
final class WindowSwitcherPanel: NSPanel {
    init(model: WindowSwitcherViewModel,
         onSelect: @escaping (CGWindowID) -> Void,
         onAction: @escaping (CGWindowID, WindowOperation) -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.contentView = NSHostingView(
            rootView: WindowSwitcherGridView(model: model, onSelect: onSelect, onAction: onAction)
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 居中于鼠标当前所在屏幕（多屏适配）。
    /// 先按 SwiftUI 内容的实际理想尺寸定窗，再算居中位置——
    /// 否则会用初始/上一会话的旧 frame 宽度算原点，窗口比预期宽时会向右偏。
    func centerOnMouseScreen() {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let screen = screens.first { $0.frame.contains(mouse) } ?? screens.first
        guard let screen else { center(); return }

        contentView?.layoutSubtreeIfNeeded()
        let ideal = contentView?.fittingSize ?? frame.size
        let sizeOK = ideal.width >= 1 && ideal.height >= 1
        var size = NSSize(width: ceil(sizeOK ? ideal.width : frame.size.width),
                          height: ceil(sizeOK ? ideal.height : frame.size.height))
        let maxWidth = screen.frame.width - 40
        let maxHeight = screen.frame.height - 40
        if size.width > maxWidth || size.height > maxHeight {
            size = NSSize(width: min(size.width, maxWidth), height: min(size.height, maxHeight))
        }
        setContentSize(size)
        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.midY - size.height / 2))
    }
}