#!/usr/bin/env swift
import Cocoa

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil) {
    // White hierarchical (filled) symbol
    let whiteCfg = NSImage.SymbolConfiguration(hierarchicalColor: .white)
    let sized = NSImage.SymbolConfiguration(pointSize: size * 0.30, weight: .bold)
    let cfg = sized.applying(whiteCfg)
    let configured = symbol.withSymbolConfiguration(cfg)
    let symbolSize = configured?.size ?? .zero
    let x = (size - symbolSize.width) / 2
    let y = (size - symbolSize.height) / 2
    configured?.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
}

image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let png = bitmap.representation(using: .png, properties: [:]) {
    let path = "/Users/bytedance/Cursor/ClipSlotsApp/build/sf_symbol.png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("Saved \(path)")
}
