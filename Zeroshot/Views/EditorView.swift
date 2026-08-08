import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 编辑页主视图：画布 + 底部工具栏
struct EditorView: View {
    @StateObject private var doc: EditDocument
    let onClose: () -> Void

    enum ToolState: Equatable {
        case select, pencil, bubble
    }

    @State private var activeTool: ToolState = .pencil
    @State private var strokeWidth: CGFloat = 3
    @State private var tempStroke: StrokeElement?
    @State private var editingBubbleID: UUID?
    @State private var bubbleText: String = ""
    @State private var hoveredBubbleID: UUID?
    @State private var selectedBubbleID: UUID?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapBubbleID: UUID?

    /// 标注拖动状态
    private enum BubbleDragMode { case move, resize, anchor }
    private enum Corner { case tl, tr, bl, br }
    private struct BubbleDragState {
        let id: UUID
        let mode: BubbleDragMode
        let corner: Corner?
        let cursorStart: CGPoint  // 拖动起始点（图像坐标）
        let startAnchor: CGPoint
        let startBox: CGRect
    }
    @State private var bubbleDrag: BubbleDragState?

    /// 标注固定配色：白色，不受画笔颜色影响
    private let bubbleAccent = Color.white
    private let bubbleBorder = Color.black.opacity(0.55)

    /// 气泡自动尺寸的上下限（图像坐标）
    private static let minBubbleWidth: CGFloat = 80
    private static let maxBubbleWidth: CGFloat = 240
    private static let minBubbleHeight: CGFloat = 34
    private static let maxBubbleHeight: CGFloat = 320

    /// 当前画笔颜色，由系统调色板驱动（默认红色）
    private var strokeColor: Color {
        get { Color(nsColor: colorPanelModel.color) }
        set { colorPanelModel.color = newValue.nsColor }
    }

    /// 用于把系统调色板的选择回调到 SwiftUI 状态
    @StateObject private var colorPanelModel = ColorPanelModel()

    // 渲染几何
    @State private var displayRect: CGRect = .zero
    @State private var scaleFactor: CGFloat = 1

    private let settings = SettingsStore.shared
    private let barHeight: CGFloat

    init(image: NSImage, onClose: @escaping () -> Void, barHeight: CGFloat = 28) {
        _doc = StateObject(wrappedValue: EditDocument(image: image))
        self.onClose = onClose
        self.barHeight = barHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            canvasArea
            Divider()
            toolbar
        }
        .frame(minWidth: 560, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - 键盘快捷键

    @State private var keyboardMonitor: Any?

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // 正在编辑标注文字：除 Esc（提交并退出编辑）外，全部放行给文本编辑器
            if self.editingBubbleID != nil {
                if event.keyCode == 53 {
                    self.commitAnyPendingEdit()
                    return nil
                }
                return event
            }
            switch (event.keyCode, flags) {
            case (6, .command):              // ⌘Z 撤销
                self.doc.undo()
                return nil
            case (6, [.command, .shift]):    // ⇧⌘Z 重做
                self.doc.redo()
                return nil
            case (1, .command):              // ⌘S 下载
                self.download()
                return nil
            case (8, .command):              // ⌘C 复制
                self.copyImage()
                return nil
            case (37, [.command]):           // ⌘L 画线（37 = L）
                self.activeTool = .pencil
                return nil
            case (17, []):                   // T 标注
                self.activeTool = .bubble
                return nil
            case (51, []), (117, []):              // Backspace / Delete 删除选中标注
                if let sel = self.selectedBubbleID {
                    self.deleteSelectedBubble()
                    return nil
                }
                return event
            case (53, []):                   // Esc 关闭编辑
                self.onClose()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Canvas { context, size in
                    // 等比适配画布居中显示
                    let fit = fitRect(for: size)
                    context.draw(Image(nsImage: doc.image), in: fit)
                    drawStrokesAndBubbles(context: context, size: size)
                }
                .gesture(canvasGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredBubbleID = hoveredBubbleID(at: location)
                    case .ended:
                        hoveredBubbleID = nil
                    }
                }

                if let bubble = editingBubble {
                    bubbleEditor(for: bubble)
                        .onChange(of: bubbleText) { updateEditingBubbleBox() }
                }
            }
            .onAppear {
                updateGeometry(size: geo.size)
            }
            .onChange(of: geo.size) { newSize in
                updateGeometry(size: newSize)
            }
        }
    }

    private func drawStrokesAndBubbles(context: GraphicsContext, size: CGSize) {
        var strokes: [StrokeElement] = []
        if let temp = tempStroke { strokes.append(temp) }
        for case .stroke(let s) in doc.elements { strokes.append(s) }
        for stroke in strokes { drawStroke(stroke, context: context) }

        for case .bubble(let b) in doc.elements {
            drawBubble(b, context: context, showText: b.id != editingBubbleID,
                       hovered: b.id == hoveredBubbleID,
                       selected: b.id == selectedBubbleID)
        }
    }

    /// 图片在当前画布中等比居中后的绘制矩形
    private func fitRect(for size: CGSize) -> CGRect {
        let imageSize = doc.image.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
            return .zero
        }
        // 只缩小、不放大：保证像素清晰；放会被限制在原始尺寸
        let scale = min(1, min(size.width / imageSize.width, size.height / imageSize.height))
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func updateGeometry(size: CGSize) {
        // displayRect 与 scaleFactor 与真实绘制矩形保持一致，供手势换算使用
        displayRect = fitRect(for: size)
        guard displayRect.width > 0 else { return }
        scaleFactor = displayRect.width / doc.image.size.width
    }

    // MARK: - 坐标转换

    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - displayRect.minX) / scaleFactor,
                y: (p.y - displayRect.minY) / scaleFactor)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scaleFactor + displayRect.minX,
                y: p.y * scaleFactor + displayRect.minY)
    }

    private func toImageRect(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - displayRect.minX) / scaleFactor,
               y: (rect.minY - displayRect.minY) / scaleFactor,
               width: rect.width / scaleFactor,
               height: rect.height / scaleFactor)
    }

    private func toViewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scaleFactor + displayRect.minX,
               y: rect.minY * scaleFactor + displayRect.minY,
               width: rect.width * scaleFactor,
               height: rect.height * scaleFactor)
    }

    // MARK: - 手势

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard displayRect.contains(value.location) else { return }
                let imgPoint = toImage(value.location)
                switch activeTool {
                case .pencil:
                    if var stroke = tempStroke {
                        stroke.points.append(imgPoint)
                        tempStroke = stroke
                    } else {
                        tempStroke = StrokeElement(points: [imgPoint],
                                                   color: strokeColor,
                                                   lineWidth: strokeWidth)
                    }
                case .bubble:
                    break
                case .select:
                    if bubbleDrag == nil {
                        startBubbleDragIfNeeded(at: value.location)
                    }
                    applyBubbleDrag(to: value.location)
                }
            }
            .onEnded { value in
                let imgPoint = toImage(value.location)
                switch activeTool {
                case .pencil:
                    if var stroke = tempStroke {
                        stroke.points.append(imgPoint)
                        if stroke.points.count > 1 {
                            doc.snapshotBeforeChange()
                            doc.elements.append(.stroke(stroke))
                        }
                        tempStroke = nil
                    }
                case .bubble:
                    doc.snapshotBeforeChange()
                    let bubble = BubbleElement(
                        anchor: imgPoint,
                        box: defaultBubbleBox(at: imgPoint),
                        text: ""
                    )
                    doc.elements.append(.bubble(bubble))
                    bubbleText = ""
                    editingBubbleID = bubble.id
                    selectedBubbleID = bubble.id
                    activeTool = .select
case .select:
                    let tap = abs(value.translation.width) < 4 && abs(value.translation.height) < 4
                    if tap {
                        if let laterHit = bubble(at: value.location), let selID = selectedBubbleID, selID == laterHit.0 {
                            // 双击打开文字编辑
                            let isDouble = Date().timeIntervalSince(lastTapTime) < 0.35 && lastTapBubbleID == selID
                            lastTapTime = Date()
                            lastTapBubbleID = selID
                            if isDouble {
                                startTextEdit(for: selID)
                            }
                        } else {
                            // 点到空白处：结束文字编辑
                            commitAnyPendingEdit()
                            selectedBubbleID = nil
                            lastTapBubbleID = nil
                        }
                    }
                    endBubbleDrag()
                }
            }
    }

    // MARK: - 标注拖动（移动 / 缩放 / 锚点）

    /// 初始文本框（图像坐标）：锚点右上、较小
    private func defaultBubbleBox(at anchor: CGPoint) -> CGRect {
        let w: CGFloat = 100
        let h: CGFloat = 34
        return CGRect(x: anchor.x + 10, y: anchor.y - h - 12, width: w, height: h)
    }

    private func bubble(at location: CGPoint) -> (UUID, BubbleElement)? {
        for case .bubble(let b) in doc.elements {
            if bubbleHitRect(b).contains(location) { return (b.id, b) }
        }
        return nil
    }

    /// 命中测试：优先缩放控点 → 锚点 → 文本框，开始拖动
    private func startBubbleDragIfNeeded(at location: CGPoint) {
        // 若正处于某个标注的文字编辑中，先提交关闭覆盖层，避免挡住拖动
        commitAnyPendingEdit()

        // 1) 当前所有标注的四个角缩放控点
        for case .bubble(let b) in doc.elements {
            let viewBox = toViewRect(b.box)
            for corner in [Corner.tl, .tr, .bl, .br] {
                let handlePos = cornerPoint(viewBox, corner)
                if CGRect(x: handlePos.x - 7, y: handlePos.y - 7, width: 14, height: 14).contains(location) {
                    selectedBubbleID = b.id
                    doc.snapshotBeforeChange()
                    bubbleDrag = BubbleDragState(id: b.id, mode: .resize, corner: corner,
                                                 cursorStart: toImage(location),
                                                 startAnchor: b.anchor, startBox: b.box)
                    return
                }
            }
        }
        // 2) 锚点
        for case .bubble(let b) in doc.elements {
            let anchorView = toView(b.anchor)
            let anchorHit = CGRect(x: anchorView.x - 9, y: anchorView.y - 9, width: 18, height: 18)
            if anchorHit.contains(location) {
                selectedBubbleID = b.id
                doc.snapshotBeforeChange()
                bubbleDrag = BubbleDragState(id: b.id, mode: .anchor, corner: nil,
                                             cursorStart: toImage(location),
                                             startAnchor: b.anchor, startBox: b.box)
                return
            }
        }
        // 3) 文本框本体 → 移动
        guard let (id, b) = bubble(at: location) else { return }
        selectedBubbleID = id
        doc.snapshotBeforeChange()
        bubbleDrag = BubbleDragState(id: id, mode: .move, corner: nil,
                                     cursorStart: toImage(location),
                                     startAnchor: b.anchor, startBox: b.box)
    }

    private func cornerPoint(_ viewBox: CGRect, _ corner: Corner) -> CGPoint {
        switch corner {
        case .tl: return CGPoint(x: viewBox.minX, y: viewBox.minY)
        case .tr: return CGPoint(x: viewBox.maxX, y: viewBox.minY)
        case .bl: return CGPoint(x: viewBox.minX, y: viewBox.maxY)
        case .br: return CGPoint(x: viewBox.maxX, y: viewBox.maxY)
        }
    }

    private func bubbleWith(id: UUID) -> (UUID, BubbleElement)? {
        guard let b = doc.elements.compactMap({
            if case .bubble(let bb) = $0, bb.id == id { return bb }
            return nil
        }).first else { return nil }
        return (id, b)
    }

    private func applyBubbleDrag(to location: CGPoint) {
        guard let drag = bubbleDrag, let index = doc.elements.firstIndex(where: { $0.id == drag.id }) else { return }
        let imgPoint = toImage(location)
        let dx = imgPoint.x - drag.cursorStart.x
        let dy = imgPoint.y - drag.cursorStart.y
        guard case .bubble(let b) = doc.elements[index] else { return }

        var newAnchor = b.anchor
        var newBox = b.box
        switch drag.mode {
        case .move:
            newAnchor = CGPoint(x: drag.startAnchor.x + dx, y: drag.startAnchor.y + dy)
            newBox = drag.startBox.offsetBy(dx: dx, dy: dy)
        case .anchor:
            newAnchor = CGPoint(x: drag.startAnchor.x + dx, y: drag.startAnchor.y + dy)
        case .resize:
            newBox = resizedBox(startBox: drag.startBox, corner: drag.corner ?? .br,
                                deltaX: dx, deltaY: dy,
                                minSize: CGSize(width: 48, height: 24))
        }
        doc.elements[index] = .bubble(BubbleElement(
            id: b.id, anchor: newAnchor, box: newBox, text: b.text))
    }

    /// 固定对角，按拖动的角调整文本框
    private func resizedBox(startBox: CGRect, corner: Corner, deltaX: CGFloat, deltaY: CGFloat, minSize: CGSize) -> CGRect {
        let opposite: CGRect = startBox
        var minX = opposite.minX
        var minY = opposite.minY
        var maxX = opposite.maxX
        var maxY = opposite.maxY
        switch corner {
        case .tl:
            minX = min(opposite.maxX - minSize.width, opposite.minX + deltaX)
            minY = min(opposite.maxY - minSize.height, opposite.minY + deltaY)
        case .tr:
            maxX = max(opposite.minX + minSize.width, opposite.maxX + deltaX)
            minY = min(opposite.maxY - minSize.height, opposite.minY + deltaY)
        case .bl:
            minX = min(opposite.maxX - minSize.width, opposite.minX + deltaX)
            maxY = max(opposite.minY + minSize.height, opposite.maxY + deltaY)
        case .br:
            maxX = max(opposite.minX + minSize.width, opposite.maxX + deltaX)
            maxY = max(opposite.minY + minSize.height, opposite.maxY + deltaY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func endBubbleDrag() {
        bubbleDrag = nil
    }

    /// 删除当前选中的标注
    private func deleteSelectedBubble() {
        guard let selID = selectedBubbleID else { return }
        doc.snapshotBeforeChange()
        doc.elements.removeAll { $0.id == selID }
        selectedBubbleID = nil
        if editingBubbleID == selID { editingBubbleID = nil }
    }

    private var editingBubble: BubbleElement? {
        guard let id = editingBubbleID else { return nil }
        return doc.elements.compactMap {
            if case .bubble(let b) = $0, b.id == id { return b }
            return nil
        }.first
    }

    // MARK: - 绘制

    private func drawStroke(_ stroke: StrokeElement, context: GraphicsContext) {
        let pts = stroke.points.map { toView($0) }
        guard pts.count >= 2, let first = pts.first else { return }
        var path = Path()
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        context.stroke(path, with: .color(stroke.color),
                       style: StrokeStyle(lineWidth: stroke.lineWidth * scaleFactor,
                                          lineCap: .round, lineJoin: .round))
    }

    // MARK: - 文字标注

    /// 标注绘制（预览）：锚点圆点 → 向右上引线 → 黑色文本框
    private func drawBubble(_ bubble: BubbleElement, context: GraphicsContext, showText: Bool, hovered: Bool, selected: Bool) {
        let anchor = toView(bubble.anchor)
        let box = toViewRect(bubble.box)
        let isActive = hovered || selected

        // 锚点圆点
        let dotRadius: CGFloat = isActive ? 4.5 : 3
        let dot = Path(ellipseIn: CGRect(x: anchor.x - dotRadius, y: anchor.y - dotRadius,
                                         width: dotRadius * 2, height: dotRadius * 2))
        context.fill(dot, with: .color(isActive ? .accentColor : bubbleAccent))
        if isActive {
            context.stroke(dot, with: .color(Color.black.opacity(0.35)), lineWidth: 1)
        }

        // 引线：锚点连到文本框底部边
        var line = Path()
        line.move(to: anchor)
        line.addLine(to: toView(bubble.lineEnd))
        context.stroke(line, with: .color(bubbleAccent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5))

        // 白色文本框（黑色文字）
        let bodyPath = RoundedRectangle(cornerRadius: 6).path(in: box)
        context.fill(bodyPath, with: .color(Color.white.opacity(0.92)))
        context.stroke(bodyPath,
                       with: .color(isActive ? .accentColor : bubbleBorder),
                       style: StrokeStyle(lineWidth: isActive ? 1.6 : 1,
                                          dash: selected ? [4, 3] : []))

        if showText, !bubble.text.isEmpty {
            let text = Text(bubble.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.black)
            context.draw(text, in: box.insetBy(dx: 6, dy: 4))
        }

        // 选中时显示四周缩放控点
        if selected {
            for corner in [Corner.tl, .tr, .bl, .br] {
                let p = cornerPoint(box, corner)
                let handle = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: handle), with: .color(.accentColor))
                context.stroke(Path(ellipseIn: handle), with: .color(.white), lineWidth: 1.2)
            }
        }
    }

    /// 命中测试：根据画布坐标返回悬停的标注框 id（文本框 + 锚点）
    private func hoveredBubbleID(at location: CGPoint) -> UUID? {
        for case .bubble(let b) in doc.elements {
            if bubbleHitRect(b).contains(location) { return b.id }
        }
        return nil
    }

    private func bubbleHitRect(_ bubble: BubbleElement) -> CGRect {
        let box = toViewRect(bubble.box).insetBy(dx: -6, dy: -6)
        let anchor = toView(bubble.anchor)
        let dot = CGRect(x: anchor.x - 6, y: anchor.y - 6, width: 12, height: 12)
        return box.union(dot)
    }

    // MARK: - 文字编辑控件

    /// 编辑态文本框：仅文字编辑视图（白框由画布 drawBubble 绘制），不遮挡整盒拖拽/缩放命中
    private func bubbleEditor(for bubble: BubbleElement) -> some View {
        let box = toViewRect(bubble.box)
        let textW = max(box.width - 12, 1)
        let textH = max(box.height - 8, 1)
        return BubbleTextView(text: $bubbleText)
            .frame(width: textW, height: textH)
            .position(x: box.midX, y: box.midY)
            .onDisappear { commitBubbleEdit(bubble) }
    }

    /// 点击存在的标注 → 进入文字编辑模式
    private func startTextEdit(for id: UUID) {
        guard let (_, b) = bubbleWith(id: id) else { return }
        bubbleText = b.text
        editingBubbleID = id
        selectedBubbleID = id
    }

    private func commitBubbleEdit(_ bubble: BubbleElement) {
        guard let index = doc.elements.firstIndex(where: { $0.id == bubble.id }) else { return }
        if case .bubble(let b) = doc.elements[index] {
            let text = bubbleText
            let box = bubbleBox(for: b.box, text: text)
            if b.box != box || b.text != text {
                doc.snapshotBeforeChange()
            }
            doc.elements[index] = .bubble(BubbleElement(
                id: b.id, anchor: b.anchor, box: box,
                text: text))
        }
        editingBubbleID = nil
    }

    /// 输入过程中实时把气泡框调整到适应文字的大小
    private func updateEditingBubbleBox() {
        guard let id = editingBubbleID,
              let index = doc.elements.firstIndex(where: { $0.id == id }),
              case .bubble(let b) = doc.elements[index] else { return }
        let box = bubbleBox(for: b.box, text: bubbleText)
        guard box != b.box else { return }
        doc.elements[index] = .bubble(BubbleElement(id: b.id, anchor: b.anchor, box: box, text: b.text))
    }

    /// 依据文字计算气泡框（图像坐标）：宽度上限 240，高度自适应；锚定右上角生长，引线出点保持稳定
    private func bubbleBox(for current: CGRect, text: String) -> CGRect {
        let size = fittedBubbleSize(for: text)
        let right = current.maxX
        let top = current.maxY
        return CGRect(x: right - size.width, y: top - size.height,
                      width: size.width, height: size.height)
    }

    private func fittedBubbleSize(for text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let maxViewWidth = Self.maxBubbleWidth * scaleFactor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, maxViewWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        let scale = max(scaleFactor, 0.01)
        let width = max(Self.minBubbleWidth,
                        min(Self.maxBubbleWidth, (bounds.width + 16) / scale))
        let height = max(Self.minBubbleHeight,
                         min(Self.maxBubbleHeight, (bounds.height + 10) / scale))
        return CGSize(width: width, height: height)
    }

    // MARK: - 工具栏

    @State private var showBrushPanel = false

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                toolButton(systemImage: "arrow.uturn.backward", tip: "撤回 (⌘Z)", disabled: !doc.canUndo) {
                    commitAnyPendingEdit()
                    doc.undo()
                }
                toolButton(systemImage: "arrow.uturn.forward", tip: "重做 (⇧⌘Z)", disabled: !doc.canRedo) {
                    commitAnyPendingEdit()
                    doc.redo()
                }
            }

            Divider().frame(height: 14)

            toolButton(systemImage: "pencil", tip: "画线 (L)", highlighted: activeTool == .pencil || showBrushPanel) {
                commitAnyPendingEdit()
                activeTool = .pencil
                showBrushPanel = true
            }
            .popover(isPresented: $showBrushPanel, arrowEdge: .top) {
                brushPanel
            }

            toolButton(systemImage: "text.bubble.fill", tip: "标注 (T)", highlighted: activeTool == .bubble) {
                commitAnyPendingEdit()
                activeTool = .bubble
                showBrushPanel = false
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                toolButton(systemImage: "arrow.down.to.line", tip: "下载保存 (⌘S)") {
                    commitAnyPendingEdit()
                    download()
                }
                toolButton(systemImage: "doc.on.doc", tip: "复制 (⌘C)") {
                    commitAnyPendingEdit()
                    copyImage()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: barHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1 / (NSScreen.main?.backingScaleFactor ?? 1))
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    /// 画笔配置面板：颜色（方形圆角）+ 粗细（三条线）
    private var brushPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("颜色")
                    .font(.system(size: 12))
                    .frame(width: 34, alignment: .leading)
                colorSquareButton
            }
            Divider()
            HStack(spacing: 10) {
                Text("粗细")
                    .font(.system(size: 12))
                    .frame(width: 34, alignment: .leading)
                HStack(spacing: 12) {
                    thicknessLineButton(width: 2)
                    thicknessLineButton(width: 5)
                    thicknessLineButton(width: 9)
                }
            }
        }
        .padding(14)
    }

    /// 方形圆角颜色按钮
    private var colorSquareButton: some View {
        Button {
            openColorPanel()
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(strokeColor)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("画笔颜色")
    }

    /// 粗细线条按钮：用线宽表示 细/中/粗。点击范围固定大尺寸，便于点选
    private func thicknessLineButton(width: CGFloat) -> some View {
        Button {
            strokeWidth = width
        } label: {
            HStack {
                Spacer(minLength: 0)
                Capsule()
                    .fill(self.strokeWidth == width ? strokeColor : Color.secondary)
                    .frame(width: 26, height: width)
                Spacer(minLength: 0)
            }
            .frame(minWidth: 44, minHeight: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.strokeWidth == width ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("粗细 \(Int(width))")
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = strokeColor.nsColor
        panel.showsAlpha = false
        colorPanelModel.color = strokeColor.nsColor
        panel.isContinuous = true
        panel.setTarget(colorPanelModel)
        panel.setAction(#selector(ColorPanelModel.colorChanged(_:)))

        // 把调色板定位到颜色按钮右上方（点击时鼠标即在按钮上）
        positionColorPanel(panel)
        panel.makeKeyAndOrderFront(nil)
    }

private func positionColorPanel(_ panel: NSColorPanel) {
        let mouse = NSEvent.mouseLocation  // 屏幕坐标（左下原点，与 setFrameOrigin 一致）
        panel.setFrameOrigin(NSPoint(x: mouse.x + 16, y: mouse.y + 8))
    }

    private func commitAnyPendingEdit() {
        if let bubble = editingBubble {
            commitBubbleEdit(bubble)
        }
    }

    private func toolButton(systemImage: String, tip: String, disabled: Bool = false, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(highlighted && !disabled ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(highlighted && !disabled ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(tip)
    }

    // MARK: - 导出

    private func exportedImage() -> NSImage {
        let size = doc.image.size
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        doc.image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

        for element in doc.elements {
            switch element {
            case .stroke(let s):
                let path = NSBezierPath()
                guard let first = s.points.first, s.points.count > 1 else { continue }
                path.move(to: first)
                for p in s.points.dropFirst() { path.line(to: p) }
                path.lineWidth = s.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                s.color.nsColor.setStroke()
                path.stroke()
            case .bubble(let b):
                drawBubbleIntoCanvas(b)
            }
        }
        canvas.unlockFocus()
        return canvas
    }

    private func drawBubbleIntoCanvas(_ bubble: BubbleElement) {
        let anchor = bubble.anchor
        let box = bubble.box

        // 锚点圆点
        let dot = NSBezierPath(ovalIn: NSRect(x: anchor.x - 3, y: anchor.y - 3, width: 6, height: 6))
        NSColor.white.setFill()
        dot.fill()

        // 引线
        let line = NSBezierPath()
        line.move(to: anchor)
        line.line(to: bubble.lineEnd)
        line.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        line.stroke()

        // 白色文本框（黑色文字）
        let body = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.92).setFill()
        body.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        body.lineWidth = 1
        body.stroke()

        if !bubble.text.isEmpty {
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let attributed = NSAttributedString(
                string: bubble.text,
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            attributed.draw(in: box.insetBy(dx: 6, dy: 4))
        }
    }

    // MARK: - 下载 / 复制

    private func download() {
        guard let data = exportedImage().pngData else {
            presentAlert(title: "保存失败", message: "无法生成图片数据")
            return
        }
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: settings.saveDirectory)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let name = Self.fileName()

        func write(to url: URL) {
            do {
                try data.write(to: url, options: .atomic)
                SettingsStore.shared.lastSavedPath = url.path
            } catch {
                presentAlert(title: "保存失败", message: error.localizedDescription)
            }
            onClose()
        }

        if settings.askSaveLocation {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name
            panel.directoryURL = dirURL
            panel.begin { response in
                if response == .OK, let url = panel.url { write(to: url) }
            }
        } else {
            var url = dirURL.appendingPathComponent(name)
            var counter = 1
            while fm.fileExists(atPath: url.path) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                url = dirURL.appendingPathComponent("\(base)-\(counter).\(ext)")
                counter += 1
            }
            write(to: url)
        }
    }

    private func copyImage() {
        let image = exportedImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = image.pngData {
            pb.setData(data, forType: .png)
        } else {
            pb.writeObjects([image])
        }
        onClose()
    }

    static func fileName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return "zeroshot_\(df.string(from: Date())).png"
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

// MARK: - 辅助

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}

// MARK: - 系统调色板回调

final class ColorPanelModel: NSObject, ObservableObject {
    @Published var color: NSColor = .red

    @objc func colorChanged(_ sender: NSColorPanel?) {
        guard let c = sender?.color else { return }
        color = c
    }
}

// MARK: - 气泡文字编辑（NSTextView 包装）

/// NSTextView 包装：创建气泡后自动聚焦、可直接输入；背景透明（白框由画布绘制）、随内容自适应
private struct BubbleTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textColor = .black
        tv.insertionPointColor = .black
        tv.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        tv.autoresizingMask = []
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }
        context.coordinator.requestFocus(nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: BubbleTextView
        private var hasRequestedFocus = false

        init(_ parent: BubbleTextView) {
            self.parent = parent
        }

        /// 首次出现时把键盘焦点交给编辑框（同一 NSTextView 只执行一次）
        func requestFocus(_ tv: NSTextView) {
            guard !hasRequestedFocus else { return }
            hasRequestedFocus = true
            DispatchQueue.main.async { [weak tv] in
                tv?.window?.makeFirstResponder(tv)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            DispatchQueue.main.async {
                self.parent.text = tv.string
            }
        }
    }
}