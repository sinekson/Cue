// Renders Cue's tvOS app icon layers and Top Shelf images into the asset
// catalog: one play, drawn like the note on Apple's Musik icon — a grey-white,
// slightly see-through glyph with a tight dark rim, on Musik's gradient, a
// little pinker.
//   swift Tools/AppIcon/render.swift [preview.png]
// Sizes are in a 400 × 240 design space and scaled per output.
// Back layer: the background. Middle: the play's shadow. Front: the play and its
// rim — on focus the play moves further than its shadow, lifting off the page.
// The Top Shelf images (shown when the Top Shelf extension has nothing) are the
// same picture flattened: the background, the play at `topShelfPlayShare` of
// their height.
// Colours are Display P3 values (as on the TV — sRGB was too tame).

import AppKit

// MARK: - Design values

let backgroundTop: UInt32 = 0xFF3873    // Musik's red (sampled sRGB FF506C → FF2840, clipped) at
let backgroundBottom: UInt32 = 0xFA014C //   its lightness, the most chroma P3 holds, hue 6° pinker
let rimColor: UInt32 = 0x69001C         //   (OKLCH 16° → 10°; the rim turned with it)
let rimAlpha: CGFloat = 0.6
let rimWidth: CGFloat = 0.6             // a sharp line just outside the edge (a blurred one looked soft)
let liftAlpha: CGFloat = 0.4            // a soft shadow under the play: it stands off the background
let liftBlur: CGFloat = 6
let liftOffset: CGFloat = 1.5           // down
let playColor: UInt32 = 0xFAF9F9        // grey-white
let playAlpha: (top: CGFloat, bottom: CGFloat) = (0.9, 0.84) // the red shows through, more at the bottom

let playHeight: CGFloat = 180           // 75 % of the icon, as Musik's note
let playCorner: CGFloat = 0.13          // × height
let playWidthRatio: CGFloat = 0.9       // width ÷ height
let opticalNudge: CGFloat = 0.03        // × height, right of the drawn shape's centre
let topShelfPlayShare: CGFloat = 0.4    // the play's height ÷ a Top Shelf image's height

// MARK: - Drawing

let design = CGSize(width: 400, height: 240)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
/// Core Graphics shadows don't follow the scale: this keeps them in design units
/// (the previews were tuned at 2×, design unit = 2 px).
var shadowScale: CGFloat = 1

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                            CGFloat(hex & 255) / 255, a])!
}

func vertical(_ ctx: CGContext, _ top: CGColor, _ bottom: CGColor, _ r: CGRect) {
    let g = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
}

/// A sharp dark line along `path`'s edge, outside it only (the play stays see-through).
func rim(_ ctx: CGContext, _ path: CGPath) {
    ctx.saveGState()
    let outside = CGMutablePath()
    outside.addRect(CGRect(origin: .zero, size: design).insetBy(dx: -50, dy: -50))
    outside.addPath(path)
    ctx.addPath(outside); ctx.clip(using: .evenOdd)
    ctx.addPath(path); ctx.setStrokeColor(rgb(rimColor, rimAlpha)); ctx.setLineWidth(rimWidth * 2); ctx.strokePath()
    ctx.restoreGState()
}

/// `path`'s soft shadow alone, whole (also under the shape — the layers shift on
/// focus, a hole would show): the shape is drawn far off and its shadow cast back.
func lift(_ ctx: CGContext, _ path: CGPath) {
    let away: CGFloat = 1000
    var off = CGAffineTransform(translationX: away, y: 0)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -away * shadowScale, height: -liftOffset * shadowScale),
                  blur: liftBlur * shadowScale, color: rgb(rimColor, liftAlpha))
    ctx.addPath(path.copy(using: &off)!); ctx.setFillColor(.black); ctx.fillPath()
    ctx.restoreGState()
}

/// A rounded play triangle, its drawn shape centred plus the optical nudge.
func playShape(height h: CGFloat) -> CGPath {
    let w = h * playWidthRatio, r = h * playCorner, cy = design.height / 2
    let a = CGPoint(x: 0, y: cy + h / 2), b = CGPoint(x: 0, y: cy - h / 2), c = CGPoint(x: w, y: cy)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: cy))
    p.addArc(tangent1End: b, tangent2End: c, radius: r)
    p.addArc(tangent1End: c, tangent2End: a, radius: r)
    p.addArc(tangent1End: a, tangent2End: b, radius: r)
    p.closeSubpath()
    var move = CGAffineTransform(translationX: design.width / 2 + h * opticalNudge - p.boundingBoxOfPath.midX, y: 0)
    return p.copy(using: &move)!
}

enum Layer: String { case back = "Back", middle = "Middle", front = "Front" }

func draw(_ layer: Layer, in ctx: CGContext) {
    switch layer {
    case .back:
        vertical(ctx, rgb(backgroundTop), rgb(backgroundBottom), CGRect(origin: .zero, size: design))
    case .middle:
        lift(ctx, playShape(height: playHeight))
    case .front:
        let play = playShape(height: playHeight)
        rim(ctx, play)
        ctx.saveGState(); ctx.addPath(play); ctx.clip()
        vertical(ctx, rgb(playColor, playAlpha.top), rgb(playColor, playAlpha.bottom), play.boundingBoxOfPath)
        ctx.restoreGState()
    }
}

func render(_ layers: [Layer], pixels: CGSize) -> Data {
    let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = pixels.width / design.width
    ctx.scaleBy(x: scale, y: scale)
    shadowScale = scale
    for layer in layers { draw(layer, in: ctx) }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// A Top Shelf image: the background over the whole of it, the icon's play
/// (with its shadow and rim) scaled up around its centre.
func renderTopShelf(points: CGSize, scale: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: Int(points.width * scale), height: Int(points.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    vertical(ctx, rgb(backgroundTop), rgb(backgroundBottom), CGRect(origin: .zero, size: points))
    let k = points.height * topShelfPlayShare / playHeight
    ctx.translateBy(x: points.width / 2 - design.width / 2 * k, y: points.height / 2 - design.height / 2 * k)
    ctx.scaleBy(x: k, y: k)
    shadowScale = scale * k
    draw(.middle, in: ctx)
    draw(.front, in: ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// MARK: - Output

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Cue/Assets.xcassets/App Icon & Top Shelf Image.brandassets").standardized
let layers: [Layer] = [.front, .middle, .back]
let fm = FileManager.default

for (stack, base) in [("App Icon", CGSize(width: 400, height: 240)),
                      ("App Icon - App Store", CGSize(width: 1280, height: 768))] {
    let stackURL = root.appendingPathComponent("\(stack).imagestack")
    // Only this script's layers stay in the stack.
    for item in (try? fm.contentsOfDirectory(atPath: stackURL.path)) ?? []
    where item.hasSuffix(".imagestacklayer") && !layers.map({ "\($0.rawValue).imagestacklayer" }).contains(item) {
        try? fm.removeItem(at: stackURL.appendingPathComponent(item))
    }
    for layer in layers {
        let set = stackURL.appendingPathComponent("\(layer.rawValue).imagestacklayer/Content.imageset")
        try? fm.removeItem(at: set)
        try! fm.createDirectory(at: set, withIntermediateDirectories: true)
        let file = layer.rawValue.lowercased()
        try! render([layer], pixels: base).write(to: set.appendingPathComponent("\(file).png"))
        try! render([layer], pixels: CGSize(width: base.width * 2, height: base.height * 2))
            .write(to: set.appendingPathComponent("\(file)@2x.png"))
        try! """
        {"images":[{"idiom":"tv","scale":"1x","filename":"\(file).png"},{"idiom":"tv","scale":"2x","filename":"\(file)@2x.png"}],"info":{"author":"xcode","version":1}}
        """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        try! #"{"info":{"author":"xcode","version":1}}"#
            .write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
    let list = layers.map { #"{"filename":"\#($0.rawValue).imagestacklayer"}"# }.joined(separator: ",")
    try! #"{"layers":[\#(list)],"info":{"author":"xcode","version":1}}"#
        .write(to: stackURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

for (set, file, points) in [("Top Shelf Image", "topshelf", CGSize(width: 1920, height: 720)),
                            ("Top Shelf Image Wide", "topshelf-wide", CGSize(width: 2320, height: 720))] {
    let url = root.appendingPathComponent("\(set).imageset")
    try! renderTopShelf(points: points, scale: 1).write(to: url.appendingPathComponent("\(file).png"))
    try! renderTopShelf(points: points, scale: 2).write(to: url.appendingPathComponent("\(file)@2x.png"))
}

if CommandLine.arguments.count > 1 {
    try! render([.back, .middle, .front], pixels: CGSize(width: 800, height: 480))
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("wrote the icon layers and Top Shelf images")
