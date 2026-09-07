import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: px, height: px)
    let g = NSGradient(colors: [NSColor(calibratedRed: 0.62, green: 0.08, blue: 0.14, alpha: 1),
                                NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.30, alpha: 1)])!
    g.draw(in: r, angle: 90)
    // soft highlight band
    let hl = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    hl.draw(in: NSRect(x: 0, y: CGFloat(px)*0.55, width: CGFloat(px), height: CGFloat(px)*0.45), angle: 90)
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let font = NSFont.systemFont(ofSize: CGFloat(px) * 0.62, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: p]
    let s = NSAttributedString(string: "完", attributes: attrs)
    let sz = s.size()
    s.draw(in: NSRect(x: 0, y: (CGFloat(px) - sz.height)/2 - CGFloat(px)*0.02, width: CGFloat(px), height: sz.height))
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(px).png"))
}
