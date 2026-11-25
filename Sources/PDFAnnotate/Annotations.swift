import AppKit
import PDFKit

// MARK: - Kinds

/// The annotation kinds this app knows how to edit. Everything except images is a
/// standard PDF annotation, so it survives saving and stays editable when reopened
/// (here or in Preview, Acrobat, etc.).
enum AnnotationKind {
    case text, highlight, rectangle, oval, line, ink, image, other
}

extension PDFAnnotation {
    var kind: AnnotationKind {
        if self is ImageAnnotation { return .image }
        switch (type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "FreeText": return .text
        case "Highlight": return .highlight
        case "Square": return .rectangle
        case "Circle": return .oval
        case "Line": return .line
        case "Ink": return .ink
        default: return .other
        }
    }

    var isEditable: Bool { kind != .other }

    /// Whether the bottom-right handle resizes this annotation.
    var isResizable: Bool { [.text, .rectangle, .oval, .ink, .image].contains(kind) }

    /// Whether the annotation's color is a stroke color (vs. text or highlight color).
    var usesStrokeColor: Bool { [.rectangle, .oval, .line, .ink].contains(kind) }

    var strokeWidth: CGFloat {
        get { border?.lineWidth ?? 1 }
        set { let b = PDFBorder(); b.lineWidth = newValue; border = b }
    }

    /// Line endpoints in page space (PDFKit stores them relative to the bounds origin).
    var pageStartPoint: CGPoint { CGPoint(x: bounds.minX + startPoint.x, y: bounds.minY + startPoint.y) }
    var pageEndPoint: CGPoint { CGPoint(x: bounds.minX + endPoint.x, y: bounds.minY + endPoint.y) }
}

// MARK: - Page rotation

/// Pages can be displayed rotated (/Rotate 90, 180, 270) while annotations live in
/// unrotated page space. Text and images should read upright for the viewer, so these
/// helpers translate between "what the viewer sees" and page coordinates.
enum Rotation {
    static func of(_ page: PDFPage?) -> Int { ((page?.rotation ?? 0) % 360 + 360) % 360 }

    static func isSideways(_ rotation: Int) -> Bool { rotation == 90 || rotation == 270 }

    /// The page-space corner of `r` that appears at the viewer's top-left.
    static func topLeft(of r: CGRect, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: return CGPoint(x: r.minX, y: r.minY)
        case 180: return CGPoint(x: r.maxX, y: r.minY)
        case 270: return CGPoint(x: r.maxX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    /// The page-space corner of `r` that appears at the viewer's bottom-right.
    static func bottomRight(of r: CGRect, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: return CGPoint(x: r.maxX, y: r.maxY)
        case 180: return CGPoint(x: r.minX, y: r.maxY)
        case 270: return CGPoint(x: r.minX, y: r.minY)
        default: return CGPoint(x: r.maxX, y: r.minY)
        }
    }

    /// Page-space rect for a box that appears `size` big with its top-left at `anchor`.
    static func rect(anchor a: CGPoint, viewerSize s: CGSize, rotation: Int) -> CGRect {
        switch rotation {
        case 90: return CGRect(x: a.x, y: a.y, width: s.height, height: s.width)
        case 180: return CGRect(x: a.x - s.width, y: a.y, width: s.width, height: s.height)
        case 270: return CGRect(x: a.x - s.height, y: a.y - s.width, width: s.height, height: s.width)
        default: return CGRect(x: a.x, y: a.y - s.height, width: s.width, height: s.height)
        }
    }

    /// How far `p` is to the right of / below `a`, as the viewer sees it.
    static func viewerOffset(from a: CGPoint, to p: CGPoint, rotation: Int) -> CGSize {
        switch rotation {
        case 90: return CGSize(width: p.y - a.y, height: p.x - a.x)
        case 180: return CGSize(width: a.x - p.x, height: p.y - a.y)
        case 270: return CGSize(width: a.y - p.y, height: a.x - p.x)
        default: return CGSize(width: p.x - a.x, height: a.y - p.y)
        }
    }

    static func viewerSize(of r: CGRect, rotation: Int) -> CGSize {
        isSideways(rotation) ? CGSize(width: r.height, height: r.width) : r.size
    }
}

// MARK: - Image annotation

/// An image placed on a page. PDFKit can't save custom image appearances, so images
/// are drawn into the page content when the document is saved (see Saving.swift).
final class ImageAnnotation: PDFAnnotation {
    let image: NSImage
    private let cgImage: CGImage?

    var aspectRatio: CGFloat {
        guard let cg = cgImage, cg.height > 0 else { return 1 }
        return CGFloat(cg.width) / CGFloat(cg.height)
    }

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        self.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        draw(in: context, rotation: Rotation.of(page))
    }

    /// Draws the image upright as seen on a page displayed with `rotation`.
    func draw(in context: CGContext, rotation: Int) {
        guard let cg = cgImage else { return }
        let size = Rotation.viewerSize(of: bounds, rotation: rotation)
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: CGFloat(rotation) * .pi / 180)
        context.draw(cg, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }
}

// MARK: - Style

struct AnnotationStyle {
    var textColor: NSColor = .black
    var strokeColor: NSColor = .systemRed
    var highlightColor: NSColor = NSColor(srgbRed: 1, green: 0.92, blue: 0.2, alpha: 1)
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 14

    var font: NSFont { AnnotationFactory.font(size: fontSize) }
}

// MARK: - Factory

enum AnnotationFactory {
    /// Extra room around free text so PDFKit's own text layout never clips or re-wraps.
    static let textInset = CGSize(width: 8, height: 4)

    /// Helvetica is a standard PDF font, so other viewers render it faithfully.
    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var f = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func text(_ string: String, font: NSFont, color: NSColor, topLeft: CGPoint, maxWidth: CGFloat?,
                     rotation: Int) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(origin: topLeft, size: CGSize(width: 1, height: 1)),
                              forType: .freeText, withProperties: nil)
        a.contents = string
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.alignment = .left
        a.strokeWidth = 0
        fitText(a, topLeft: topLeft, width: nil, maxWidth: maxWidth, rotation: rotation)
        return a
    }

    /// The page-space point where a text annotation's first line starts (as the viewer sees it).
    static func textAnchor(_ a: PDFAnnotation) -> CGPoint {
        Rotation.topLeft(of: a.bounds, rotation: Rotation.of(a.page))
    }

    /// Sizes a free-text annotation to its text, keeping its viewer top-left at `topLeft`.
    /// With `width` nil, uses the natural (unwrapped) width capped at `maxWidth`;
    /// otherwise wraps to `width`. Widths are as the viewer sees them.
    static func fitText(_ a: PDFAnnotation, topLeft: CGPoint, width: CGFloat?, maxWidth: CGFloat? = nil,
                        rotation: Int? = nil) {
        let font = a.font ?? self.font(size: 14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var string = a.contents ?? ""
        if string.isEmpty { string = " " }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

        var w: CGFloat
        if let width {
            w = width
        } else {
            let natural = (string as NSString).boundingRect(
                with: CGSize(width: 100_000, height: 100_000), options: options, attributes: attrs)
            w = ceil(natural.width) + textInset.width
            if let maxWidth { w = min(w, maxWidth) }
        }
        w = max(w, font.pointSize + textInset.width)
        let r = (string as NSString).boundingRect(
            with: CGSize(width: w - textInset.width, height: 100_000), options: options, attributes: attrs)
        let h = ceil(r.height) + textInset.height
        a.bounds = Rotation.rect(anchor: topLeft, viewerSize: CGSize(width: w, height: h),
                                 rotation: rotation ?? Rotation.of(a.page))
    }

    static func shape(_ kind: AnnotationKind, rect: CGRect, color: NSColor, lineWidth: CGFloat) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: kind == .oval ? .circle : .square, withProperties: nil)
        a.color = color
        a.strokeWidth = lineWidth
        return a
    }

    static func line(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat, arrow: Bool) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: .zero, forType: .line, withProperties: nil)
        a.color = color
        a.strokeWidth = lineWidth
        if arrow { a.endLineStyle = .openArrow }
        setLine(a, start: start, end: end)
        return a
    }

    /// Positions a line annotation from page-space endpoints.
    static func setLine(_ a: PDFAnnotation, start: CGPoint, end: CGPoint) {
        let pad = max(a.strokeWidth * 4, 8)  // room for arrow heads
        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                       width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -pad, dy: -pad)
        a.bounds = r
        a.startPoint = CGPoint(x: start.x - r.minX, y: start.y - r.minY)
        a.endPoint = CGPoint(x: end.x - r.minX, y: end.y - r.minY)
    }

    static func ink(points: [CGPoint], color: NSColor, lineWidth: CGFloat) -> PDFAnnotation? {
        guard points.count > 1 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let pad = lineWidth + 2
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -pad, dy: -pad)
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: points[0].x - r.minX, y: points[0].y - r.minY))
        for p in points.dropFirst() { path.line(to: CGPoint(x: p.x - r.minX, y: p.y - r.minY)) }
        let a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
        a.add(path)
        a.color = color
        a.strokeWidth = lineWidth
        return a
    }

    /// One highlight covering each given rect (e.g. each line of a text selection).
    static func highlight(rects: [CGRect], color: NSColor) -> PDFAnnotation? {
        let rects = rects.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let a = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
        a.color = color
        a.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
            let x0 = r.minX - union.minX, x1 = r.maxX - union.minX
            let y0 = r.minY - union.minY, y1 = r.maxY - union.minY
            return [CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0)]
                .map { NSValue(point: $0) }
        }
        return a
    }

    /// An opaque white box used to cover original page text being replaced.
    static func whiteout(rect: CGRect) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = .white
        a.interiorColor = .white
        a.strokeWidth = 0
        return a
    }
}

// MARK: - Undo snapshots

/// A snapshot of the editable properties of an annotation, used for undo/redo.
struct AnnotationState {
    let bounds: CGRect
    let color: NSColor
    let fontColor: NSColor?
    let font: NSFont?
    let contents: String?
    let strokeWidth: CGFloat
    let startPoint: CGPoint
    let endPoint: CGPoint
    let paths: [NSBezierPath]

    init(_ a: PDFAnnotation) {
        bounds = a.bounds
        color = a.color
        fontColor = a.fontColor
        font = a.font
        contents = a.contents
        strokeWidth = a.strokeWidth
        startPoint = a.startPoint
        endPoint = a.endPoint
        paths = (a.paths ?? []).map { $0.copy() as! NSBezierPath }
    }

    func apply(to a: PDFAnnotation) {
        switch a.kind {
        case .image:
            break
        case .text:
            a.contents = contents
            if let font { a.font = font }
            if let fontColor { a.fontColor = fontColor }
        case .highlight:
            a.color = color
        case .rectangle, .oval:
            a.color = color
            a.strokeWidth = strokeWidth
        case .line:
            a.color = color
            a.strokeWidth = strokeWidth
            a.startPoint = startPoint
            a.endPoint = endPoint
        case .ink:
            a.color = color
            a.strokeWidth = strokeWidth
            for p in a.paths ?? [] { a.remove(p) }
            for p in paths { a.add(p.copy() as! NSBezierPath) }
        case .other:
            break
        }
        a.bounds = bounds
    }
}
