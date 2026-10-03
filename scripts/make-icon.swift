import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("QuickFind.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (pixels, suffix) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let p = CGFloat(pixels)
    let bg = NSBezierPath(roundedRect: NSRect(x: p*0.07, y:p*0.07, width:p*0.86, height:p*0.86), xRadius:p*0.19, yRadius:p*0.19)
    NSGradient(starting: NSColor(calibratedRed:0.12,green:0.30,blue:0.71,alpha:1), ending:NSColor(calibratedRed:0.11,green:0.62,blue:0.77,alpha:1))!.draw(in:bg, angle:45)
    NSColor.white.withAlphaComponent(0.96).setStroke()
    let lens = NSBezierPath(ovalIn:NSRect(x:p*0.24,y:p*0.36,width:p*0.38,height:p*0.38))
    lens.lineWidth = p*0.065; lens.stroke()
    let handle = NSBezierPath(); handle.move(to:NSPoint(x:p*0.59,y:p*0.39)); handle.line(to:NSPoint(x:p*0.75,y:p*0.23))
    handle.lineWidth = p*0.085; handle.lineCapStyle = .round; handle.stroke()
    NSColor(calibratedRed:0.67,green:1,blue:0.86,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:p*0.32,y:p*0.54,width:p*0.20,height:p*0.04),xRadius:p*0.02,yRadius:p*0.02).fill()
    NSBezierPath(roundedRect:NSRect(x:p*0.32,y:p*0.45,width:p*0.14,height:p*0.04),xRadius:p*0.02,yRadius:p*0.02).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
    try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("icon_\(suffix).png"))
}
