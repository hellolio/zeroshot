import SwiftUI

/// 画布元素
enum CanvasElement: Identifiable, Equatable {
    case stroke(StrokeElement)
    case bubble(BubbleElement)

    var id: UUID {
        switch self {
        case .stroke(let s): return s.id
        case .bubble(let b): return b.id
        }
    }

    static func == (lhs: CanvasElement, rhs: CanvasElement) -> Bool {
        switch (lhs, rhs) {
        case (.stroke(let a), .stroke(let b)): return a.id == b.id && a.points == b.points && a.color == b.color && a.lineWidth == b.lineWidth
        case (.bubble(let a), .bubble(let b)): return a.id == b.id && a.anchor == b.anchor && a.box == b.box && a.text == b.text
        default: return false
        }
    }
}

struct StrokeElement: Identifiable, Equatable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
}

/// 文字标注：锚点（引线起点）+ 文本框（可拖动位置、缩放下、固定白色、不被画笔影响）
struct BubbleElement: Identifiable, Equatable {
    let id: UUID   // 稳定标识；重新构造（改位置/缩放/文字）时必须沿用原名，否则所有按 id 的记录（编辑覆盖层、拖动报错）会失效
    var anchor: CGPoint   // 引线起点（锚点圆点位置，图像坐标）
    var box: CGRect        // 文本框，图像坐标；位置和大小都可在编辑时调整
    var text: String

    init(anchor: CGPoint, box: CGRect, text: String) {
        self.id = UUID()
        self.anchor = anchor
        self.box = box
        self.text = text
    }

    init(id: UUID, anchor: CGPoint, box: CGRect, text: String) {
        self.id = id
        self.anchor = anchor
        self.box = box
        self.text = text
    }

    /// 文本框在锚点右上方时的底部中心点（引线连接处）
    var lineEnd: CGPoint {
        CGPoint(x: box.midX, y: box.maxY)
    }
}

/// 编辑文档：持有原始图片 + 编辑对象 + 撤销/重做栈
final class EditDocument: ObservableObject {
    @Published var image: NSImage
    @Published var elements: [CanvasElement] = []

    private var undoStack: [[CanvasElement]] = []
    private var redoStack: [[CanvasElement]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: NSImage) {
        self.image = image
    }

    @discardableResult
    func snapshotBeforeChange() -> Bool {
        let current = elements
        if case .some(let last) = undoStack.last, last == current { return false }
        undoStack.append(current)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        return true
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = last
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = last
    }

    func resetUndoRedo(keepingCurrent: Bool = true) {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}