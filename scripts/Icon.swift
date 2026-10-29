import AppKit
let output=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let ctx=NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    let rect=NSRect(x:28,y:28,width:968,height:968)
    let bg=NSBezierPath(roundedRect:rect,xRadius:215,yRadius:215)
    NSGradient(starting:NSColor(calibratedRed:0.055,green:0.10,blue:0.18,alpha:1),ending:NSColor(calibratedRed:0.035,green:0.21,blue:0.27,alpha:1))!.draw(in:bg,angle:55)
    let eye=NSBezierPath();eye.move(to:NSPoint(x:173,y:512));eye.curve(to:NSPoint(x:851,y:512),controlPoint1:NSPoint(x:355,y:796),controlPoint2:NSPoint(x:669,y:796));eye.curve(to:NSPoint(x:173,y:512),controlPoint1:NSPoint(x:669,y:228),controlPoint2:NSPoint(x:355,y:228));eye.close();NSColor(calibratedWhite:0.97,alpha:1).setFill();eye.fill()
    let iris=NSBezierPath(ovalIn:NSRect(x:377,y:377,width:270,height:270));NSColor(calibratedRed:0.20,green:0.83,blue:0.76,alpha:1).setFill();iris.fill()
    let pupil=NSBezierPath(ovalIn:NSRect(x:442,y:442,width:140,height:140));NSColor(calibratedRed:0.04,green:0.12,blue:0.18,alpha:1).setFill();pupil.fill()
    NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:480,y:519,width:38,height:38)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data=bitmap.representation(using:.png,properties:[:])!
    let names:[String]
    switch size {case 16:names=["icon_16x16.png"];case 32:names=["icon_16x16@2x.png","icon_32x32.png"];case 64:names=["icon_32x32@2x.png"];case 128:names=["icon_128x128.png"];case 256:names=["icon_128x128@2x.png","icon_256x256.png"];case 512:names=["icon_256x256@2x.png","icon_512x512.png"];default:names=["icon_512x512@2x.png"]}
    for name in names{try data.write(to:URL(fileURLWithPath:output).appendingPathComponent(name))}
}
