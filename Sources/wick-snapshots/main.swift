import AppKit
import SwiftUI
import WickCore
import WickUI

// Renders each panel state to a PNG, so the UI can be checked and documented without clicking through it.
// Usage: swift run wick-snapshots <output directory>

let output = URL(filePath: CommandLine.arguments.dropFirst().first ?? "snapshots", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let inTwoHours = Date.now.addingTimeInterval(1 * 3600 + 42 * 60 + 9)

let scenes: [(name: String, model: WickModel)] = [
    ("idle", .preview()),
    ("idle-forever", .preview(forever: true, agents: ["Claude Code"])),
    ("awake", .preview(
        phase: .awake(Session(endsAt: inTwoHours, untilAgentsFinish: true)),
        agents: ["Claude Code", "Codex"],
        agentsOn: true,
        battery: Battery(percent: 62, isDischarging: true)
    )),
    ("awake-forever", .preview(
        phase: .awake(Session(endsAt: nil)),
        forever: true,
        battery: Battery(percent: 91, isDischarging: false)
    )),
    ("awake-elsewhere", .preview(phase: .awakeElsewhere)),
    ("needs-access", .preview(needsAccess: true)),
    ("ended-battery", .preview(
        lastEnd: SessionEnd(reason: .lowBattery)
    )),
    ("awake-warm", .preview(
        phase: .awake(Session(endsAt: inTwoHours)),
        battery: Battery(percent: 71, isDischarging: false),
        heat: Heat(level: .fair, isLidClosed: false, batteryCelsius: 38)
    )),
    ("ended-heat", .preview(
        heat: Heat(level: .serious, isLidClosed: false, batteryCelsius: 46),
        lastEnd: SessionEnd(reason: .overheating)
    )),
    ("problem", .preview(problem: "Couldn't turn sleep off. Something went wrong in pmset.")),
    ("desktop-mac", .preview(battery: nil)),
    ("worst-case", .preview(
        phase: .awake(Session(endsAt: .now.addingTimeInterval(11 * 3600 + 58 * 60), untilAgentsFinish: true, batteryFloor: 50)),
        agents: ["Claude Code", "Cursor Agent", "Gemini CLI", "OpenCode"],
        agentsOn: true,
        battery: Battery(percent: 100, isDischarging: true)
    )),
]

struct Stage: View {
    let model: WickModel

    var body: some View {
        PanelView(model: model)
            .padding(36)
            .background(LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.13), Color(red: 0.12, green: 0.10, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            ))
    }
}

for scene in scenes {
    let view = NSHostingView(rootView: Stage(model: scene.model))
    let size = view.fittingSize
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    window.orderFront(nil)
    RunLoop.current.run(until: .now.addingTimeInterval(0.25))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let file = output.appending(path: "\(scene.name).png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    window.orderOut(nil)
    print(file.path)
}

// The menu bar glyphs, on both menu bar colours.
for (name, isAwake, dark) in [("glyph-off", false, true), ("glyph-on", true, true), ("glyph-on-light", true, false)] {
    let canvas = NSImage(size: NSSize(width: 44, height: 28), flipped: false) { rect in
        (dark ? NSColor.black : NSColor.white).setFill()
        rect.fill()
        let glyph = WickGlyph.statusImage(isAwake: isAwake)
        let tint = NSImage(size: glyph.size, flipped: false) { tintRect in
            glyph.draw(in: tintRect)
            (dark ? NSColor.white : NSColor.black).set()
            tintRect.fill(using: .sourceIn)
            return true
        }
        tint.draw(in: NSRect(x: 13, y: 5, width: 18, height: 18))
        return true
    }
    let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 176, pixelsHigh: 112, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    scaled.size = NSSize(width: 44, height: 28)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    canvas.draw(in: NSRect(x: 0, y: 0, width: 44, height: 28))
    NSGraphicsContext.restoreGraphicsState()
    try scaled.representation(using: .png, properties: [:])?.write(to: output.appending(path: "\(name).png"))
}

// The real window, from the real controller: transparent margins, shadow, material and anchoring included.
let realScenes: [(String, WickModel)] = [
    ("real-idle", .preview(agents: ["Claude Code"], battery: Battery(percent: 84, isDischarging: false))),
    ("real-awake", .preview(
        phase: .awake(Session(endsAt: inTwoHours, untilAgentsFinish: true)),
        agents: ["Claude Code"],
        agentsOn: true,
        battery: Battery(percent: 62, isDischarging: true)
    )),
]
for (name, model) in realScenes {
    let controller = StatusController(model: model)
    // The menu bar places a new item on the next pass. Opening before that has nothing to anchor to.
    RunLoop.current.run(until: .now.addingTimeInterval(1.5))
    let panelWindow = controller.openForSnapshot()
    RunLoop.current.run(until: .now.addingTimeInterval(0.6))
    print(name, "frame", panelWindow.frame, "screen", NSScreen.main?.frame ?? .zero, "key", panelWindow.isKeyWindow)
    if let image = CGWindowListCreateImage(
        .null, .optionIncludingWindow, CGWindowID(panelWindow.windowNumber), [.boundsIgnoreFraming, .bestResolution]
    ) {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: output.appending(path: "\(name).png"))
    }
    panelWindow.orderOut(nil)
}
