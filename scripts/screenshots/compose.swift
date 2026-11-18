// Cleans up a raw screen capture for the README:
//  - repaints the menu bar strip with the generated wallpaper, except inside the Pulse capsule
//    (hides the real desktop picture and other apps' menu bar icons),
//  - crops, and rounds the corners.
// Usage: swift compose.swift <shot.png> <wall.png> <out.png>
//        <menuBarHeight> <capsuleX> <capsuleY> <capsuleW> <capsuleH>
//        <cropX> <cropY> <cropW> <cropH> <cornerRadius>
// All coordinates are top-left based, in capture pixels.
import AppKit

let a = CommandLine.arguments
func d(_ i: Int) -> CGFloat { CGFloat(Double(a[i])!) }
let shot = NSImage(contentsOfFile: a[1])!
let wall = NSImage(contentsOfFile: a[2])!
let outPath = a[3]
let menuBar = d(4)
let capsule = CGRect(x: d(5), y: d(6), width: d(7), height: d(8))
let crop = CGRect(x: d(9), y: d(10), width: d(11), height: d(12))
let corner = d(13)

func cg(_ image: NSImage) -> CGImage {
    var r = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &r, context: nil, hints: nil)!
}
let shotCG = cg(shot), wallCG = cg(wall)
let W = CGFloat(shotCG.width), H = CGFloat(shotCG.height)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let full = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip to top-left coordinates.
full.translateBy(x: 0, y: H)
full.scaleBy(x: 1, y: -1)
func drawTL(_ img: CGImage, in ctx: CGContext, rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}
drawTL(shotCG, in: full, rect: CGRect(x: 0, y: 0, width: W, height: H))

// Menu bar strip minus the capsule -> wallpaper.
full.saveGState()
let clip = CGMutablePath()
clip.addRect(CGRect(x: 0, y: 0, width: W, height: menuBar))
clip.addRoundedRect(in: capsule, cornerWidth: capsule.height / 2, cornerHeight: capsule.height / 2)
full.addPath(clip)
full.clip(using: .evenOdd)
drawTL(wallCG, in: full, rect: CGRect(x: 0, y: 0, width: CGFloat(wallCG.width), height: CGFloat(wallCG.height)))
full.restoreGState()

let composed = full.makeImage()!
// makeImage() is in bitmap (top-left row order) space; crop directly.
let cropped = composed.cropping(to: crop)!

let out = CGContext(data: nil, width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(origin: .zero, size: crop.size)
out.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
out.clip()
out.draw(cropped, in: rect)

let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote", outPath, Int(crop.width), "x", Int(crop.height))
