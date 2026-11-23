import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels)/128)
    transform.concat()
    let shape = NSBezierPath(roundedRect: NSRect(x:7,y:7,width:114,height:114),xRadius:27,yRadius:27)
    NSGradient(starting: NSColor(red:0.08,green:0.38,blue:0.37,alpha:1), ending: NSColor(red:0.03,green:0.14,blue:0.23,alpha:1))!.draw(in: shape,angle: -68)
    NSColor(white: 1,alpha: 0.92).setFill()
    NSBezierPath(ovalIn:NSRect(x:35,y:68,width:29,height:29)).fill()
    NSBezierPath(roundedRect:NSRect(x:23,y:37,width:54,height:25),xRadius:12,yRadius:12).fill()
    NSColor(red:0.42,green:0.95,blue:0.74,alpha:1).setStroke()
    let check = NSBezierPath()
    check.move(to:NSPoint(x:72,y:61)); check.line(to:NSPoint(x:82,y:51)); check.line(to:NSPoint(x:102,y:77))
    check.lineWidth = 8; check.lineJoinStyle = .round; check.lineCapStyle = .round; check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("icon_" + name + ".png"))
}
