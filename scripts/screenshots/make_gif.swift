// Builds a looping GIF from PNG frames.
// Usage: swift make_gif.swift <out.gif> <frameDelaySeconds> <frame1.png> [frame2.png ...]
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1])
let delay = Double(a[2])!
let frames = Array(a.dropFirst(3))

guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
    fatalError("cannot create \(out.path)")
}
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

let frameProps = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
] as CFDictionary

for path in frames {
    guard
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { continue }
    CGImageDestinationAddImage(dest, image, frameProps)
}
guard CGImageDestinationFinalize(dest) else { fatalError("failed to write gif") }
print("wrote", out.path, frames.count, "frames")
