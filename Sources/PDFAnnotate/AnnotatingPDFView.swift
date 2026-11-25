import AppKit
import PDFKit

enum Tool: Int, CaseIterable {
    case select, text, editText, highlight, rectangle, oval, line, arrow, pen

    var title: String {
        switch self {
        case .select: return "Select"
        case .text: return "Add Text"
        case .editText: return "Edit Page Text"
        case .highlight: return "Highlight"
        case .rectangle: return "Rectangle"
        case .oval: return "Oval"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .pen: return "Draw"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .editText: return "character.cursor.ibeam"
        case .highlight: return "highlighter"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        }
    }

    /// Single-key shortcut (no modifiers) while the page has focus.
    var key: String {
        switch self {
        case .select: return "v"
        case .text: return "t"
        case .editText: return "e"
        case .highlight: return "h"
        case .rectangle: return "r"
        case .oval: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .pen: return "d"
        }
    }
}

protocol AnnotatingPDFViewDelegate: AnyObject {
    func annotatingViewDidChange(_ view: AnnotatingPDFView)
    func annotatingViewSelectionDidChange(_ view: AnnotatingPDFView)
    func annotatingViewToolDidChange(_ view: AnnotatingPDFView)
    func annotatingView(_ view: AnnotatingPDFView, promptForText title: String, initial: String) -> String?
    func annotatingViewRequestsPaste(_ view: AnnotatingPDFView)
}

/// Draws selection handles and in-progress shapes above the PDF. Never receives clicks.
final class OverlayView: NSView {
    weak var owner: AnnotatingPDFView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { owner?.drawOverlay(in: self) }
}

final class AnnotatingPDFView: PDFView {
    weak var annotationDelegate: AnnotatingPDFViewDelegate?
    var style = AnnotationStyle()

    var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            gesture = nil
            deselectAll()
            window?.invalidateCursorRects(for: self)
            overlay.needsDisplay = true
            annotationDelegate?.annotatingViewToolDidChange(self)
        }
    }

    private(set) var selectedAnnotation: PDFAnnotation? {
        didSet {
            guard oldValue !== selectedAnnotation else { return }
            coalescingTarget = nil
            overlay.needsDisplay = true
            annotationDelegate?.annotatingViewSelectionDidChange(self)
        }
    }

    private enum Gesture {
        case move(PDFAnnotation, start: CGPoint, original: AnnotationState)
        case resize(PDFAnnotation, original: AnnotationState)
        case lineEnd(PDFAnnotation, isStart: Bool, original: AnnotationState)
        case create(Tool, PDFPage, start: CGPoint, current: CGPoint, points: [CGPoint])
    }
    private var gesture: Gesture?
    private var gestureChanged = false
    private weak var coalescingTarget: PDFAnnotation?

    private let overlay = OverlayView()
    private var observers: [NSObjectProtocol] = []
    private weak var observedClip: NSClipView?

    /// Handle size in page units, so handles stay the same size on screen at any zoom.
    private var handleSize: CGFloat { 9 / max(scaleFactor, 0.01) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.owner = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        let nc = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDisplayModeChanged] {
            observers.append(nc.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                self?.overlay.needsDisplay = true
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var document: PDFDocument? {
        didSet {
            gesture = nil
            selectedAnnotation = nil
            undoManager?.removeAllActions()
            DispatchQueue.main.async { self.attachOverlay() }
        }
    }

    /// PDFView rebuilds its subviews when a document is set; keep the overlay on top
    /// and redraw it whenever the pages scroll.
    private func attachOverlay() {
        addSubview(overlay, positioned: .above, relativeTo: nil)
        if let clip = documentView?.enclosingScrollView?.contentView, clip !== observedClip {
            observedClip = clip
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.overlay.needsDisplay = true })
        }
        overlay.needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Selection

    func select(_ annotation: PDFAnnotation?) { selectedAnnotation = annotation }

    /// Deselects the annotation and any text selection.
    private func deselectAll() {
        selectedAnnotation = nil
        clearSelection()
    }

    // MARK: - Undoable model changes

    func addAnnotation(_ a: PDFAnnotation, to page: PDFPage, actionName: String, select: Bool = true) {
        page.addAnnotation(a)
        undoManager?.registerUndo(withTarget: self) { $0.removeAnnotation(a, actionName: actionName) }
        undoManager?.setActionName(actionName)
        if select { selectedAnnotation = a }
        changed(page)
    }

    func removeAnnotation(_ a: PDFAnnotation, actionName: String = "Delete") {
        guard let page = a.page else { return }
        if selectedAnnotation === a { selectedAnnotation = nil }
        page.removeAnnotation(a)
        undoManager?.registerUndo(withTarget: self) { $0.addAnnotation(a, to: page, actionName: actionName) }
        undoManager?.setActionName(actionName)
        changed(page)
    }

    private func restore(_ a: PDFAnnotation, to state: AnnotationState, actionName: String) {
        let current = AnnotationState(a)
        state.apply(to: a)
        undoManager?.registerUndo(withTarget: self) { $0.restore(a, to: current, actionName: actionName) }
        undoManager?.setActionName(actionName)
        coalescingTarget = nil
        changed(a.page)
    }

    private func registerChange(_ a: PDFAnnotation, from original: AnnotationState, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { $0.restore(a, to: original, actionName: actionName) }
        undoManager?.setActionName(actionName)
    }

    /// Applies `body` to the selected annotation as one undoable step. With `coalescing`,
    /// repeated calls on the same annotation (e.g. dragging in the color panel) share one undo step.
    func modifySelected(_ actionName: String, coalescing: Bool = false, _ body: (PDFAnnotation) -> Void) {
        guard let a = selectedAnnotation else { return }
        let before = AnnotationState(a)
        body(a)
        if !(coalescing && coalescingTarget === a) { registerChange(a, from: before, actionName: actionName) }
        coalescingTarget = coalescing ? a : nil
        changed(a.page)
    }

    func deleteSelected() {
        guard let a = selectedAnnotation else { return }
        removeAnnotation(a)
    }

    private func changed(_ page: PDFPage?) {
        if let page { annotationsChanged(on: page) }
        needsDisplay = true
        overlay.needsDisplay = true
        annotationDelegate?.annotatingViewDidChange(self)
    }

    // MARK: - Text

    /// Room between a text anchor and the page's right edge, as the viewer sees it.
    private func maxTextWidth(from anchor: CGPoint, on page: PDFPage) -> CGFloat {
        let rotation = Rotation.of(page)
        let edge = Rotation.bottomRight(of: page.bounds(for: displayBox), rotation: rotation)
        return max(Rotation.viewerOffset(from: anchor, to: edge, rotation: rotation).width - 4, 60)
    }

    func editText(of a: PDFAnnotation) {
        guard a.kind == .text, let page = a.page,
              let text = annotationDelegate?.annotatingView(self, promptForText: "Edit Text", initial: a.contents ?? "")
        else { return }
        if text.isEmpty { removeAnnotation(a); return }
        selectedAnnotation = a
        modifySelected("Edit Text") { a in
            a.contents = text
            let anchor = AnnotationFactory.textAnchor(a)
            AnnotationFactory.fitText(a, topLeft: anchor, width: nil, maxWidth: maxTextWidth(from: anchor, on: page))
        }
    }

    private func createText(at point: CGPoint, on page: PDFPage) {
        guard let text = annotationDelegate?.annotatingView(self, promptForText: "Add Text", initial: ""),
              !text.isEmpty else { return }
        let a = AnnotationFactory.text(text, font: style.font, color: style.textColor, topLeft: point,
                                       maxWidth: maxTextWidth(from: point, on: page), rotation: Rotation.of(page))
        addAnnotation(a, to: page, actionName: "Add Text")
    }

    /// Covers original page text with a white box and places editable text on top.
    private func replacePageText(_ selection: PDFSelection, on page: PDFPage) {
        let original = selection.string ?? ""
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        setCurrentSelection(selection, animate: false)
        defer { clearSelection() }
        guard let newText = annotationDelegate?.annotatingView(self, promptForText: "Edit Page Text", initial: original),
              newText != original else { return }

        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        guard let first = rects.first else { return }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }

        // Match the original font as closely as we can.
        let attrs = selection.attributedString?.attributes(at: 0, effectiveRange: nil) ?? [:]
        let srcFont = attrs[.font] as? NSFont
        let size = srcFont?.pointSize ?? style.fontSize
        let traits = srcFont?.fontDescriptor.symbolicTraits ?? []
        let cleanName = srcFont.map { $0.fontName.components(separatedBy: "+").last ?? $0.fontName }
        let font = cleanName.flatMap { NSFont(name: $0, size: size) }
            ?? AnnotationFactory.font(size: size, bold: traits.contains(.bold), italic: traits.contains(.italic))
        let color = (attrs[.foregroundColor] as? NSColor) ?? .black

        undoManager?.beginUndoGrouping()
        for r in rects {
            addAnnotation(AnnotationFactory.whiteout(rect: r.insetBy(dx: -1, dy: -1)), to: page,
                          actionName: "Edit Page Text", select: false)
        }
        if !newText.isEmpty {
            let topLeft = Rotation.topLeft(of: union.insetBy(dx: -2, dy: -2), rotation: Rotation.of(page))
            let a = AnnotationFactory.text(newText, font: font, color: color, topLeft: topLeft,
                                           maxWidth: maxTextWidth(from: topLeft, on: page), rotation: Rotation.of(page))
            addAnnotation(a, to: page, actionName: "Edit Page Text")
        }
        undoManager?.endUndoGrouping()
    }

    // MARK: - Hit testing

    private func annotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        let tolerance = handleSize
        return page.annotations.reversed().first { a in
            guard a.isEditable else { return false }
            if a.kind == .line {
                return distance(from: point, toSegment: a.pageStartPoint, a.pageEndPoint) <= max(tolerance, a.strokeWidth)
            }
            return a.bounds.insetBy(dx: -tolerance / 3, dy: -tolerance / 3).contains(point)
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func near(_ p: CGPoint, _ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= handleSize }

    /// The handle sits at the corner that appears bottom-right on screen.
    private func resizeHandle(of a: PDFAnnotation) -> CGPoint {
        Rotation.bottomRight(of: a.bounds, rotation: Rotation.of(a.page))
    }

    // MARK: - Mouse

    private func pagePoint(_ event: NSEvent, nearest: Bool) -> (PDFPage, CGPoint)? {
        let v = convert(event.locationInWindow, from: nil)
        guard let page = page(for: v, nearest: nearest) else { return nil }
        return (page, convert(v, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        gestureChanged = false
        guard let (page, p) = pagePoint(event, nearest: false) else {
            deselectAll()
            if tool == .select { super.mouseDown(with: event) }
            return
        }

        switch tool {
        case .select:
            if let a = selectedAnnotation, a.page == page {
                if a.kind == .line {
                    if near(p, a.pageStartPoint) { gesture = .lineEnd(a, isStart: true, original: AnnotationState(a)); return }
                    if near(p, a.pageEndPoint) { gesture = .lineEnd(a, isStart: false, original: AnnotationState(a)); return }
                } else if a.isResizable, near(p, resizeHandle(of: a)) {
                    gesture = .resize(a, original: AnnotationState(a)); return
                }
            }
            if let a = annotation(at: p, on: page) {
                selectedAnnotation = a
                if event.clickCount == 2, a.kind == .text { gesture = nil; editText(of: a); return }
                gesture = .move(a, start: p, original: AnnotationState(a))
                return
            }
            gesture = nil
            deselectAll()
            super.mouseDown(with: event)

        case .text:
            if let a = annotation(at: p, on: page), a.kind == .text {
                selectedAnnotation = a
                editText(of: a)
            } else {
                createText(at: p, on: page)
            }

        default:
            if tool == .editText, let a = annotation(at: p, on: page), a.kind == .text {
                selectedAnnotation = a
                editText(of: a)
                return
            }
            deselectAll()
            gesture = .create(tool, page, start: p, current: p, points: [p])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let g = gesture else { return super.mouseDragged(with: event) }
        let page: PDFPage? = {
            switch g {
            case .move(let a, _, _), .resize(let a, _), .lineEnd(let a, _, _): return a.page
            case .create(_, let page, _, _, _): return page
            }
        }()
        guard let page else { return }
        documentView?.autoscroll(with: event)
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        let shift = event.modifierFlags.contains(.shift)
        gestureChanged = true

        switch g {
        case .move(let a, let start, let original):
            var b = original.bounds
            b.origin.x += p.x - start.x
            b.origin.y += p.y - start.y
            a.bounds = b

        case .resize(let a, let original):
            resize(a, original: original, to: p, shift: shift)

        case .lineEnd(let a, let isStart, _):
            var target = p
            let fixed = isStart ? a.pageEndPoint : a.pageStartPoint
            if shift { target = snap45(from: fixed, to: p) }
            AnnotationFactory.setLine(a, start: isStart ? target : fixed, end: isStart ? fixed : target)

        case .create(let tool, let page, let start, _, var points):
            var current = p
            if shift, tool == .line || tool == .arrow { current = snap45(from: start, to: p) }
            if shift, tool == .rectangle || tool == .oval {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                current = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
            }
            if tool == .pen { points.append(p) }
            gesture = .create(tool, page, start: start, current: current, points: points)
            if tool == .highlight || tool == .editText {
                setCurrentSelection(page.selection(from: start, to: p), animate: false)
            }
            overlay.needsDisplay = true
            return
        }
        annotationsChanged(on: page)
        overlay.needsDisplay = true
    }

    /// Resizes from the on-screen bottom-right handle, keeping the on-screen top-left fixed.
    /// Sizes are computed as the viewer sees them so this also works on rotated pages.
    private func resize(_ a: PDFAnnotation, original: AnnotationState, to p: CGPoint, shift: Bool) {
        let rotation = Rotation.of(a.page)
        let o = original.bounds
        let anchor = Rotation.topLeft(of: o, rotation: rotation)
        let oldSize = Rotation.viewerSize(of: o, rotation: rotation)
        let drag = Rotation.viewerOffset(from: anchor, to: p, rotation: rotation)
        let minSize: CGFloat = 8
        var w = max(drag.width, minSize)
        var h = max(drag.height, minSize)
        switch a.kind {
        case .text:
            AnnotationFactory.fitText(a, topLeft: anchor, width: w)
            return
        case .image:
            if !shift { h = w / ((a as? ImageAnnotation)?.aspectRatio ?? 1) }
        case .rectangle, .oval:
            if shift { w = max(w, h); h = w }
        case .ink:
            if !shift { h = w * oldSize.height / max(oldSize.width, 1) }
        default:
            return
        }
        let newBounds = Rotation.rect(anchor: anchor, viewerSize: CGSize(width: w, height: h), rotation: rotation)
        if a.kind == .ink {
            // Ink paths are relative to the bounds origin, so scaling them fills the new box.
            let sx = newBounds.width / max(o.width, 1), sy = newBounds.height / max(o.height, 1)
            for path in a.paths ?? [] { a.remove(path) }
            for path in original.paths {
                let scaled = path.copy() as! NSBezierPath
                scaled.transform(using: AffineTransform(scaleByX: sx, byY: sy))
                a.add(scaled)
            }
        }
        a.bounds = newBounds
    }

    private func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    override func mouseUp(with event: NSEvent) {
        guard let g = gesture else { return super.mouseUp(with: event) }
        gesture = nil
        overlay.needsDisplay = true

        switch g {
        case .move(let a, _, let original):
            if gestureChanged { registerChange(a, from: original, actionName: "Move"); changed(a.page) }
        case .resize(let a, let original):
            if gestureChanged { registerChange(a, from: original, actionName: "Resize"); changed(a.page) }
        case .lineEnd(let a, _, let original):
            if gestureChanged { registerChange(a, from: original, actionName: "Move Line End"); changed(a.page) }
        case .create(let tool, let page, let start, let end, let points):
            finishCreate(tool, page: page, start: start, end: end, points: points, dragged: gestureChanged)
        }
    }

    private func finishCreate(_ tool: Tool, page: PDFPage, start: CGPoint, end: CGPoint, points: [CGPoint], dragged: Bool) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let bigEnough = rect.width >= 3 || rect.height >= 3

        switch tool {
        case .rectangle, .oval:
            guard rect.width >= 3, rect.height >= 3 else { return }
            let a = AnnotationFactory.shape(tool == .oval ? .oval : .rectangle, rect: rect,
                                            color: style.strokeColor, lineWidth: style.lineWidth)
            addAnnotation(a, to: page, actionName: tool.title)

        case .line, .arrow:
            guard bigEnough else { return }
            let a = AnnotationFactory.line(from: start, to: end, color: style.strokeColor,
                                           lineWidth: style.lineWidth, arrow: tool == .arrow)
            addAnnotation(a, to: page, actionName: tool.title)

        case .pen:
            guard let a = AnnotationFactory.ink(points: points, color: style.strokeColor, lineWidth: style.lineWidth)
            else { return }
            addAnnotation(a, to: page, actionName: "Draw")

        case .highlight:
            let selection = dragged ? page.selection(from: start, to: end) : page.selectionForWord(at: start)
            clearSelection()
            let hasText = !(selection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let rects: [CGRect]
            if hasText, let selection {
                rects = selection.selectionsByLine().map { $0.bounds(for: page) }
            } else if rect.width >= 3, rect.height >= 3 {
                rects = [rect]  // no text under the drag: highlight the dragged area
            } else {
                return
            }
            if let a = AnnotationFactory.highlight(rects: rects, color: style.highlightColor) {
                addAnnotation(a, to: page, actionName: "Highlight")
            }

        case .editText:
            let selection = dragged ? page.selection(from: start, to: end) : page.selectionForLine(at: start)
            guard let selection else { NSSound.beep(); return }
            replacePageText(selection, on: page)

        case .select, .text:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if tool == .select { return super.mouseMoved(with: event) }
        cursorForTool.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        if tool == .select { return super.cursorUpdate(with: event) }
        cursorForTool.set()
    }

    private var cursorForTool: NSCursor {
        switch tool {
        case .select: return .arrow
        case .text, .editText, .highlight: return .iBeam
        default: return .crosshair
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, gesture == nil, let chars = event.charactersIgnoringModifiers?.lowercased(),
           let t = Tool.allCases.first(where: { $0.key == chars }) {
            tool = t
            return
        }
        switch event.keyCode {
        case 53:  // escape
            if selectedAnnotation != nil { deselectAll() } else { tool = .select }
            return
        case 51, 117:  // delete, forward delete
            if selectedAnnotation != nil { deleteSelected(); return }
        case 36, 76:  // return
            if let a = selectedAnnotation, a.kind == .text { editText(of: a); return }
        case 123, 124, 125, 126:  // arrows nudge
            if selectedAnnotation != nil {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let d: CGPoint = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0),
                                  125: CGPoint(x: 0, y: -step), 126: CGPoint(x: 0, y: step)][event.keyCode]!
                modifySelected("Move", coalescing: true) { $0.bounds = $0.bounds.offsetBy(dx: d.x, dy: d.y) }
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    @objc func paste(_ sender: Any?) { annotationDelegate?.annotatingViewRequestsPaste(self) }

    // MARK: - Overlay drawing

    func drawOverlay(in view: NSView) {
        func pt(_ p: CGPoint, _ page: PDFPage) -> CGPoint { view.convert(convert(p, from: page), from: self) }
        func rect(_ r: CGRect, _ page: PDFPage) -> CGRect {
            let a = pt(CGPoint(x: r.minX, y: r.minY), page), b = pt(CGPoint(x: r.maxX, y: r.maxY), page)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        func handle(at p: CGPoint, round: Bool = false) {
            let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
            let path = round ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
            NSColor.white.setFill(); path.fill()
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
        }

        if let a = selectedAnnotation, let page = a.page {
            if a.kind == .line {
                handle(at: pt(a.pageStartPoint, page), round: true)
                handle(at: pt(a.pageEndPoint, page), round: true)
            } else {
                let outline = NSBezierPath(rect: rect(a.bounds, page).insetBy(dx: -1, dy: -1))
                outline.setLineDash([4, 3], count: 2, phase: 0)
                outline.lineWidth = 1
                NSColor.controlAccentColor.setStroke()
                outline.stroke()
                if a.isResizable { handle(at: pt(resizeHandle(of: a), page)) }
            }
        }

        guard case .create(let tool, let page, let start, let end, let points)? = gesture else { return }
        let width = style.lineWidth * scaleFactor
        style.strokeColor.setStroke()
        let r = rect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y)), page)
        let path: NSBezierPath
        switch tool {
        case .rectangle: path = NSBezierPath(rect: r)
        case .oval: path = NSBezierPath(ovalIn: r)
        case .line, .arrow:
            path = NSBezierPath()
            path.move(to: pt(start, page))
            path.line(to: pt(end, page))
        case .pen:
            path = NSBezierPath()
            path.move(to: pt(points[0], page))
            points.dropFirst().forEach { path.line(to: pt($0, page)) }
        case .highlight where currentSelection?.string?.isEmpty ?? true:
            style.highlightColor.withAlphaComponent(0.4).setFill()
            r.fill()
            return
        default:
            return
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
