#!/usr/bin/env swift
// Shows every window the running Stackshot owns: where it is, whether it's on screen,
// its opacity, and which desktops (Spaces) it belongs to. The first thing to run when
// "the stack isn't showing".
//
//   swift scripts/windows.swift
//
// Layers: 3 is the stack and floating panels, 25 the recording bar, 1000 the capture overlay.
// A stack that is ordered in but missing from the active desktop's list is stranded on another desktop.
import AppKit

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.leonmiltiadou.stackshot" }) else {
    print("Stackshot isn't running")
    exit(1)
}

// Private but long-stable window server calls, only used for this diagnostic.
let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
typealias MainConnection = @convention(c) () -> Int32
typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
let connection = unsafeBitCast(dlsym(cg, "CGSMainConnectionID"), to: MainConnection.self)()
let spacesFor = unsafeBitCast(dlsym(cg, "CGSCopySpacesForWindows"), to: SpacesForWindows.self)
let activeSpace = unsafeBitCast(dlsym(cg, "CGSGetActiveSpace"), to: ActiveSpace.self)(connection)

print("Stackshot pid \(app.processIdentifier), hidden \(app.isHidden), active desktop \(activeSpace)")
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier {
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    let spaces = (spacesFor(connection, 7, [id] as CFArray)?.takeRetainedValue() as? [UInt64]) ?? []
    let frame = "\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)) \(Int(bounds["Width"] ?? 0))×\(Int(bounds["Height"] ?? 0))"
    let desktops = spaces.isEmpty ? "none" : spaces.count > 3 ? "all \(spaces.count)" : spaces.map(String.init).joined(separator: ",")
    print("window \(id)  layer \(layer)  \(frame)  onscreen \(onScreen)  alpha \(String(format: "%.2f", alpha))  desktops \(desktops)")
}
