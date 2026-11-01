// fit <in.png> <out.png> <width> <height>
//
// Scales a screenshot to fit width x height, keeping its proportions, and fills
// the margin by stretching the picture's own edge pixels outward, so the status
// bar, the screen and the home indicator each carry on to the canvas edge.
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let W = Int(args[3]), let H = Int(args[4]),
  let source = NSImage(contentsOfFile: args[1])?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  FileHandle.standardError.write("usage: fit in.png out.png width height\n".data(using: .utf8)!)
  exit(2)
}

let scale = min(Double(W) / Double(source.width), Double(H) / Double(source.height))
let w = (Double(source.width) * scale).rounded()
let h = (Double(source.height) * scale).rounded()
let x = ((Double(W) - w) / 2).rounded(.down)
let y = ((Double(H) - h) / 2).rounded(.down)

let ctx = CGContext(
  data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high

// One pixel row or column near the source's edge, stretched across a margin.
// Taken a few pixels in: a simulator capture's outermost corner pixels are black.
func edge(_ rect: CGRect, into target: CGRect) {
  guard target.width > 0, target.height > 0, let strip = source.cropping(to: rect) else { return }
  ctx.draw(strip, in: target)
}
let sw = Double(source.width), sh = Double(source.height), inset = 4.0
// CoreGraphics puts y = 0 at the bottom; image crops put it at the top.
edge(CGRect(x: inset, y: 0, width: 1, height: sh), into: CGRect(x: 0, y: y, width: x, height: h))
edge(
  CGRect(x: sw - 1 - inset, y: 0, width: 1, height: sh),
  into: CGRect(x: x + w, y: y, width: Double(W) - x - w, height: h))
edge(
  CGRect(x: 0, y: sh - 1 - inset, width: sw, height: 1),
  into: CGRect(x: 0, y: 0, width: Double(W), height: y))
edge(
  CGRect(x: 0, y: inset, width: sw, height: 1),
  into: CGRect(x: 0, y: y + h, width: Double(W), height: Double(H) - y - h))
ctx.draw(source, in: CGRect(x: x, y: y, width: w, height: h))

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: args[2]))
