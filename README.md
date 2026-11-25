# PDF Annotate

A small native macOS app for marking up PDFs: add text, highlight, draw shapes, lines and
freehand strokes, place images, edit text already on the page, and save.

Built with AppKit and PDFKit. It has no dependencies and doesn't need Xcode; the Command Line Tools are enough.

## Build & run

```bash
./build_app.sh
open "build/PDF Annotate.app"
```

Requires macOS 13 or later. The script builds a release binary, wraps it in an app bundle
using `icon.png` as the app icon, and ad-hoc signs it. Drag the app into `/Applications`
to keep it. To make it your default PDF app, use Finder → Get Info on a PDF → Open with →
PDF Annotate → Change All.

To change the icon, replace `icon.png` with a square image (1024×1024 or larger works best)
and run the script again.

## Using it

Open a PDF with **⌘O**, drag it onto the app icon, or use Finder's **Open With**. Pick a tool
from the toolbar or press its key while the page has focus:

| Tool | Key | How to use |
|---|---|---|
| Select | `V` | Click to select. Drag to move. Drag the corner handle to resize. Drag a line's end dots to adjust them. |
| Add Text | `T` | Click where the text should start, then type it. Click existing text to edit it. |
| Edit Page Text | `E` | Click a line of the PDF's own text, or drag across part of it, then type the replacement. |
| Highlight | `H` | Drag across text to highlight it. Drag over a blank area to highlight that rectangle. |
| Rectangle | `R` | Drag to draw. Hold Shift for a square. |
| Oval | `O` | Drag to draw. Hold Shift for a circle. |
| Line | `L` | Drag to draw. Hold Shift to snap to 45° angles. |
| Arrow | `A` | Like Line, with an arrowhead. |
| Draw | `D` | Freehand pen. |

**Images:** use **Add Image** (⌘I) or paste an image with **⌘V**. Images keep their proportions
when resized. Hold Shift to resize them freely.

**Style:** the color well, line width and font size controls apply to whatever is selected.
They also set the style for the next item you create. Text, shapes and highlights each remember
their own color.

**Editing shortcuts**

- Double-click text, or press Return, to edit it.
- Delete removes the selected item.
- Arrow keys nudge the selection by 1 pt; hold Shift for 10 pt.
- Esc deselects, or switches back to the Select tool.
- **⌘Z** / **⇧⌘Z** undo and redo.
- **⌘+** / **⌘−** / **⌘0** zoom in, zoom out and zoom to fit.

**Saving:** **⌘S** saves over the open file and **⇧⌘S** saves a copy. The app asks before you
close or quit with unsaved changes.

## How saving works

- **Text, highlights, shapes, lines and drawings** are saved as standard PDF annotations.
  They look the same in Preview, Acrobat, Chrome and other viewers, and you can still edit
  them when you reopen the file in this app or in Preview.
- **Images** become part of the page when you save, because PDF has no standard editable
  image annotation. Before you save they can be moved freely. In a reopened file they're
  fixed. Only pages that contain an added image get rewritten. Other pages are saved
  untouched.
- **Edit Page Text** covers the original words with a white box and puts new text on top.
  The original text is hidden, not deleted, so it can still be found by search or
  copy/paste. The replacement uses the original font and size when the font is installed on
  your Mac, and Helvetica otherwise. It works best on white backgrounds.

## Project layout

```
Package.swift                      Swift package (executable target)
build_app.sh                       Builds build/PDF Annotate.app, including the icon
icon.png                           App icon source
Sources/PDFAnnotate/
  main.swift                       App delegate, menus, window, toolbar, open/save
  AnnotatingPDFView.swift          PDFView subclass: tools, mouse/keyboard, overlay, undo
  Annotations.swift                Annotation factory, image annotation, rotation math, undo snapshots
  Saving.swift                     Writes the PDF; bakes images into their pages
```

For quick debug runs without bundling, use `swift run`. The app runs but has no icon and no
Finder integration.
