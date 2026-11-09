#!/usr/bin/env swift
// Renders one PDF page to a PNG (white background), e.g. to test image import of sheet music.
// Usage: swift pdf_page_to_png.swift in.pdf out.png [dpi=200] [page=1]
import AppKit
import PDFKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let document = PDFDocument(url: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write(Data("usage: pdf_page_to_png.swift in.pdf out.png [dpi] [page]\n".utf8))
    exit(2)
}
let dpi = arguments.count > 3 ? Double(arguments[3]) ?? 200 : 200
let pageIndex = (arguments.count > 4 ? Int(arguments[4]) ?? 1 : 1) - 1
guard let page = document.page(at: pageIndex) else { exit(1) }
let bounds = page.bounds(for: .mediaBox)
let scale = dpi / 72
let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.cgContext.setFillColor(NSColor.white.cgColor)
context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.cgContext.scaleBy(x: scale, y: scale)
page.draw(with: .mediaBox, to: context.cgContext)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(arguments[2]) (\(width)×\(height))")
