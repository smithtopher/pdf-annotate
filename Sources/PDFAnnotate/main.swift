import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Window controller

final class EditorController: NSObject, NSWindowDelegate, AnnotatingPDFViewDelegate {
    let window: NSWindow
    let pdfView = AnnotatingPDFView(frame: .zero)

    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let widthPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontStepper = NSStepper()
    private let placeholder = NSTextField(labelWithString: "Open a PDF to get started  (⌘O)")
    private var documentControls: [NSControl] = []
    private var deleteButton: NSButton!

    private static let lineWidths: [CGFloat] = [1, 2, 3, 4, 6, 8, 12]

    private(set) var fileURL: URL?
    private var isDirty = false { didSet { window.isDocumentEdited = isDirty } }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "PDF Annotate"
        window.minSize = NSSize(width: 820, height: 400)
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        buildUI()
        syncStyleControls()
        updateControls()
    }

    // MARK: UI

    private func iconButton(_ title: String, _ symbol: String, _ action: Selector, showTitle: Bool = false) -> NSButton {
        let b = NSButton(title: showTitle ? title : "", target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = showTitle ? .imageLeading : .imageOnly
        b.bezelStyle = .rounded
        b.toolTip = title
        return b
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    private func buildUI() {
        let open = iconButton("Open… (⌘O)", "folder", #selector(openDocument(_:)))
        let image = iconButton("Add Image… (⌘I)", "photo.badge.plus", #selector(addImage(_:)))
        deleteButton = iconButton("Delete Selected (⌫)", "trash", #selector(deleteSelection(_:)))
        let save = iconButton("Save", "square.and.arrow.down", #selector(saveDocument(_:)), showTitle: true)

        toolPicker.segmentCount = Tool.allCases.count
        toolPicker.trackingMode = .selectOne
        for t in Tool.allCases {
            toolPicker.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title), forSegment: t.rawValue)
            toolPicker.setToolTip("\(t.title) (\(t.key.uppercased()))", forSegment: t.rawValue)
            toolPicker.setWidth(30, forSegment: t.rawValue)
        }
        toolPicker.selectedSegment = Tool.select.rawValue
        toolPicker.target = self
        toolPicker.action = #selector(toolPicked(_:))

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Color"

        for w in Self.lineWidths { widthPopup.addItem(withTitle: "\(Int(w)) pt") }
        widthPopup.target = self
        widthPopup.action = #selector(lineWidthChanged(_:))
        widthPopup.toolTip = "Line width"

        fontSizeField.formatter = {
            let f = NumberFormatter(); f.minimum = 4; f.maximum = 200; f.maximumFractionDigits = 1; return f
        }()
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged(_:))
        fontSizeField.toolTip = "Font size"
        fontSizeField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        fontStepper.minValue = 4; fontStepper.maxValue = 200; fontStepper.increment = 1
        fontStepper.target = self
        fontStepper.action = #selector(fontSizeChanged(_:))

        documentControls = [image, toolPicker, colorWell, widthPopup, fontSizeField, fontStepper, save]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [
            open, divider(), toolPicker, image, divider(),
            colorWell, widthPopup,
            NSImageView(image: NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Font size")!),
            fontSizeField, fontStepper,
            spacer, deleteButton, save,
        ])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.annotationDelegate = self

        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .secondaryLabelColor

        let content = NSView()
        for v in [bar, pdfView, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
        ])
        window.contentView = content
    }

    private func updateControls() {
        let hasDoc = pdfView.document != nil
        documentControls.forEach { $0.isEnabled = hasDoc }
        deleteButton.isEnabled = pdfView.selectedAnnotation != nil
        placeholder.isHidden = hasDoc
    }

    // MARK: Style controls

    private enum ColorTarget { case text, stroke, highlight, none }

    /// What the color well edits: the selected annotation's color, or the active tool's.
    private var colorTarget: ColorTarget {
        if let a = pdfView.selectedAnnotation {
            switch a.kind {
            case .text: return .text
            case .highlight: return .highlight
            case .rectangle, .oval, .line, .ink: return .stroke
            case .image, .other: break
            }
        }
        switch pdfView.tool {
        case .text, .editText: return .text
        case .highlight: return .highlight
        case .rectangle, .oval, .line, .arrow, .pen: return .stroke
        case .select: return pdfView.selectedAnnotation == nil ? .stroke : .none
        }
    }

    private func syncStyleControls() {
        var style = pdfView.style
        // Adopt the selection's look so new items match what you just picked.
        if let a = pdfView.selectedAnnotation {
            switch a.kind {
            case .text:
                if let c = a.fontColor { style.textColor = c }
                if let f = a.font { style.fontSize = f.pointSize }
            case .highlight: style.highlightColor = a.color
            case .rectangle, .oval, .line, .ink:
                style.strokeColor = a.color
                style.lineWidth = a.strokeWidth
            default: break
            }
            pdfView.style = style
        }
        switch colorTarget {
        case .text: colorWell.color = style.textColor
        case .highlight: colorWell.color = style.highlightColor
        case .stroke: colorWell.color = style.strokeColor
        case .none: break
        }
        colorWell.isEnabled = pdfView.document != nil && colorTarget != .none
        let idx = Self.lineWidths.firstIndex { $0 >= style.lineWidth } ?? Self.lineWidths.count - 1
        widthPopup.selectItem(at: idx)
        fontSizeField.doubleValue = Double(style.fontSize)
        fontStepper.doubleValue = Double(style.fontSize)
    }

    @objc func toolPicked(_ sender: NSSegmentedControl) {
        pdfView.tool = Tool(rawValue: sender.selectedSegment) ?? .select
        window.makeFirstResponder(pdfView)
    }

    @objc func selectTool(_ sender: NSMenuItem) { pdfView.tool = Tool(rawValue: sender.tag) ?? .select }

    @objc func colorChanged(_ sender: NSColorWell) {
        let c = sender.color
        switch colorTarget {
        case .text: pdfView.style.textColor = c
        case .highlight: pdfView.style.highlightColor = c
        case .stroke: pdfView.style.strokeColor = c
        case .none: return
        }
        pdfView.modifySelected("Change Color", coalescing: true) { a in
            if a.kind == .text { a.fontColor = c } else if a.kind != .image { a.color = c }
        }
    }

    @objc func lineWidthChanged(_ sender: NSPopUpButton) {
        let w = Self.lineWidths[max(sender.indexOfSelectedItem, 0)]
        pdfView.style.lineWidth = w
        guard let a = pdfView.selectedAnnotation, a.usesStrokeColor else { return }
        pdfView.modifySelected("Change Line Width") { a in
            if a.kind == .line {
                let (s, e) = (a.pageStartPoint, a.pageEndPoint)
                a.strokeWidth = w
                AnnotationFactory.setLine(a, start: s, end: e)  // re-pad bounds for the new width
            } else {
                a.strokeWidth = w
            }
        }
    }

    @objc func fontSizeChanged(_ sender: NSControl) {
        let size = CGFloat(sender.doubleValue)
        fontSizeField.doubleValue = Double(size)
        fontStepper.doubleValue = Double(size)
        pdfView.style.fontSize = size
        guard let a = pdfView.selectedAnnotation, a.kind == .text, a.font?.pointSize != size else { return }
        pdfView.modifySelected("Change Font Size", coalescing: true) { a in
            a.font = (a.font ?? AnnotationFactory.font(size: size)).withSize(size)
            AnnotationFactory.fitText(a, topLeft: AnnotationFactory.textAnchor(a), width: nil)
        }
    }

    // MARK: Open

    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    @discardableResult
    func open(url: URL) -> Bool {
        // Load into memory so we can safely overwrite the same file on save.
        guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open “\(url.lastPathComponent)”."
            alert.informativeText = "The file is not a readable PDF."
            alert.runModal()
            return false
        }
        if doc.isLocked {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is password protected."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Unlock"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn, doc.unlock(withPassword: field.stringValue) else {
                return false
            }
        }
        pdfView.document = doc
        pdfView.tool = .select
        fileURL = url
        isDirty = false
        window.title = url.lastPathComponent
        window.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateControls()
        syncStyleControls()
        window.makeFirstResponder(pdfView)
        return true
    }

    // MARK: Text prompt

    private func promptForText(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Press ⌘↩ or click OK when done."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.string = initial
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = tv
        alert.accessoryView = scroll
        let ok = alert.addButton(withTitle: "OK")
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tv
        tv.selectAll(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Images

    @objc func addImage(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        place(image)
    }

    @objc func paste(_ sender: Any?) {
        guard pdfView.document != nil,
              let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        else { NSSound.beep(); return }
        place(image)
    }

    private func place(_ image: NSImage) {
        guard let page = pdfView.currentPage else { return }
        let pageBox = page.bounds(for: pdfView.displayBox)
        var size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(1, pageBox.width * 0.5 / max(size.width, size.height), pageBox.height * 0.5 / max(size.width, size.height))
        size = CGSize(width: size.width * scale, height: size.height * scale)
        if Rotation.isSideways(Rotation.of(page)) { size = CGSize(width: size.height, height: size.width) }
        let center = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
        let x = min(max(center.x - size.width / 2, pageBox.minX), pageBox.maxX - size.width)
        let y = min(max(center.y - size.height / 2, pageBox.minY), pageBox.maxY - size.height)
        pdfView.tool = .select
        pdfView.addAnnotation(ImageAnnotation(image: image, bounds: CGRect(x: x, y: y, width: size.width, height: size.height)),
                              to: page, actionName: "Add Image")
    }

    // MARK: Edit / view

    @objc func deleteSelection(_ sender: Any?) { pdfView.deleteSelected() }

    @objc func zoomInDocument(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOutDocument(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }

    // MARK: Save

    @objc func saveDocument(_ sender: Any?) {
        guard let url = fileURL else { return saveDocumentAs(sender) }
        _ = write(to: url)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard pdfView.document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileURL.map {
            $0.deletingPathExtension().lastPathComponent + " annotated.pdf"
        } ?? "Annotated.pdf"
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(to: url) {
            fileURL = url
            window.title = url.lastPathComponent
            window.representedURL = url
        }
    }

    private func write(to url: URL) -> Bool {
        guard let doc = pdfView.document else { return false }
        guard let data = PDFSaver.data(for: doc) else {
            showError("Couldn't produce the PDF.")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            isDirty = false
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Save failed"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Unsaved changes

    /// Returns true if it's OK to proceed (saved or discarded).
    func confirmDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(fileURL?.lastPathComponent ?? "document")”?"
        alert.informativeText = "Your annotations will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(nil)
            return !isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardChanges() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // MARK: AnnotatingPDFViewDelegate

    func annotatingViewDidChange(_ view: AnnotatingPDFView) { isDirty = true; updateControls() }

    func annotatingViewSelectionDidChange(_ view: AnnotatingPDFView) {
        syncStyleControls()
        updateControls()
    }

    func annotatingViewToolDidChange(_ view: AnnotatingPDFView) {
        toolPicker.selectedSegment = view.tool.rawValue
        syncStyleControls()
    }

    func annotatingView(_ view: AnnotatingPDFView, promptForText title: String, initial: String) -> String? {
        promptForText(title: title, initial: initial)
    }

    func annotatingViewRequestsPaste(_ view: AnnotatingPDFView) { paste(view) }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: EditorController!
    private var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
        editor = EditorController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        editor.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let url = pendingURL { editor.open(url: url); pendingURL = nil }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if editor == nil { pendingURL = url; return }
        if editor.confirmDiscardChanges() { editor.open(url: url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = submenu(main, "PDF Annotate")
        appMenu.addItem(withTitle: "About PDF Annotate",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PDF Annotate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit PDF Annotate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        file.addItem(withTitle: "Open…", action: #selector(EditorController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: #selector(EditorController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(EditorController.saveDocumentAs(_:)), keyEquivalent: "S")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Actions use the responder chain; the editor receives them as the window's delegate.
        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Add Image…", action: #selector(EditorController.addImage(_:)), keyEquivalent: "i")
        edit.addItem(withTitle: "Delete", action: #selector(EditorController.deleteSelection(_:)), keyEquivalent: "")

        let tools = submenu(main, "Tools")
        for t in Tool.allCases {
            let item = tools.addItem(withTitle: t.title, action: #selector(EditorController.selectTool(_:)), keyEquivalent: "")
            item.tag = t.rawValue
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
        }

        let view = submenu(main, "View")
        view.addItem(withTitle: "Zoom In", action: #selector(EditorController.zoomInDocument(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(EditorController.zoomOutDocument(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(EditorController.zoomToFit(_:)), keyEquivalent: "0")

        NSApp.mainMenu = main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
