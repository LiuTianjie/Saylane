import Foundation
import CoreGraphics

// IME menu icons use PDF page size as their intrinsic NSImage size.
// Preserve the artwork, but normalize its page and drawing to 16 points.
let args = CommandLine.arguments
guard args.count == 3,
      let document = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL),
      let page = document.page(at: 1) else { fatalError("Usage: normalize-menu-icon input.pdf output.pdf") }
var bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
guard let context = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: &bounds, nil) else {
    fatalError("Cannot create PDF")
}
context.beginPDFPage(nil)
context.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
context.drawPDFPage(page)
context.endPDFPage()
context.closePDF()
guard let result = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL),
      let resultPage = result.page(at: 1), resultPage.getBoxRect(.mediaBox) == bounds else {
    fatalError("Menu icon dimensions failed validation")
}
print("Verified menu icon PDF: 16 × 16 pt")
