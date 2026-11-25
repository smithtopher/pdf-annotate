import AppKit
import PDFKit

enum PDFSaver {
    /// Produces the PDF to write to disk.
    ///
    /// Text, highlights, shapes, lines and drawings are standard PDF annotations, so
    /// they're saved as-is and stay editable. Images can't be stored as editable
    /// annotations, so pages that contain images are re-rendered with the images
    /// drawn into the page content. Pages without images are left untouched.
    static func data(for document: PDFDocument) -> Data? {
        // Pull images out so they aren't serialized as blank stamp annotations.
        var imagesByPage: [Int: [ImageAnnotation]] = [:]
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let images = page.annotations.compactMap { $0 as? ImageAnnotation }
            guard !images.isEmpty else { continue }
            imagesByPage[i] = images
            images.forEach(page.removeAnnotation)
        }
        defer {
            for (i, images) in imagesByPage {
                images.forEach { document.page(at: i)?.addAnnotation($0) }
            }
        }

        guard let data = document.dataRepresentation() else { return nil }
        if imagesByPage.isEmpty { return data }
        guard let output = PDFDocument(data: data) else { return nil }

        for (i, images) in imagesByPage {
            guard let source = document.page(at: i), let target = output.page(at: i),
                  let baked = bakedPage(source, images: images) else { return nil }
            // Carry over every annotation (ours and the original file's links, notes, etc.).
            for a in target.annotations {
                target.removeAnnotation(a)
                baked.addAnnotation(a)
            }
            output.removePage(at: i)
            output.insert(baked, at: i)
        }
        return output.dataRepresentation()
    }

    /// Renders the page's original content plus the images into a new single page with
    /// the same boxes and rotation, so existing annotation coordinates remain valid.
    private static func bakedPage(_ page: PDFPage, images: [ImageAnnotation]) -> PDFPage? {
        guard let pageRef = page.pageRef else { return nil }
        var media = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.drawPDFPage(pageRef)  // original content, in its own coordinate space, unrotated
        for image in images { image.draw(in: ctx, rotation: Rotation.of(page)) }
        ctx.endPDFPage()
        ctx.closePDF()

        guard let newPage = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
            newPage.setBounds(page.bounds(for: box), for: box)
        }
        newPage.rotation = page.rotation
        return newPage
    }
}
