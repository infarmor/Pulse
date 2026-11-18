// Prints on-screen windows owned by a process as "id x y w h layer".
// Usage: swift list_windows.swift <pid>
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in info where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
    guard
        let id = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Double]
    else { continue }
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    print(id, Int(bounds["X"]!), Int(bounds["Y"]!), Int(bounds["Width"]!), Int(bounds["Height"]!), layer)
}
