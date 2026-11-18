import AppKit
import Combine
import ImageIO
import SwiftUI

extension Notification.Name {
    static let openMivoriDesktopPet = Self("io.macdesk.mivori.openDesktopPet")
}

@MainActor
final class MivoriDesktopPet: ObservableObject {
    static let shared = MivoriDesktopPet()
    private static let enabledKey = "mivori.desktopPet.visible"
    private static let positionKey = "mivori.desktopPet.origin"

    @Published private(set) var isVisible = false
    private var floating: PetPanel?
    private var canvas: PetCanvas?
    private var timer: Timer?
    private var idleStart = ProcessInfo.processInfo.systemUptime
    private var laughStart: TimeInterval?
    private var dragStart: TimeInterval?

    private init() {}

    func restoreVisibility() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            setVisible(true)
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible {
            let panel = floating ?? makePanel()
            place(panel)
            idleStart = ProcessInfo.processInfo.systemUptime
            isVisible = true
            panel.orderFrontRegardless()
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 24, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.canvas?.needsDisplay = true }
            }
        } else {
            timer?.invalidate()
            timer = nil
            floating?.orderOut(nil)
            dragStart = nil
            laughStart = nil
            isVisible = false
        }
        UserDefaults.standard.set(isVisible, forKey: Self.enabledKey)
    }

    func laugh() {
        laughStart = ProcessInfo.processInfo.systemUptime
        canvas?.needsDisplay = true
    }

    fileprivate func setDragging(_ active: Bool) {
        dragStart = active ? ProcessInfo.processInfo.systemUptime : nil
        if active { laughStart = nil }
        canvas?.needsDisplay = true
    }

    fileprivate func frame(now: TimeInterval) -> (row: Int, index: Int, laughing: Bool) {
        if let dragStart {
            return (2, min(2, Int(max(0, now - dragStart) / 0.14)), false)
        }
        if let laughStart, now - laughStart < 1.68 {
            return (1, Self.index((now - laughStart).truncatingRemainder(dividingBy: 0.84),
                                  durations: [0.14, 0.14, 0.14, 0.14, 0.28]), true)
        }
        let elapsed = now - (laughStart.map { $0 + 1.68 } ?? idleStart)
        return (0, Self.index(max(0, elapsed).truncatingRemainder(dividingBy: 2.62),
                              durations: [1.1, 0.1, 0.24, 0.23, 0.1, 0.21, 0.64]), false)
    }

    private static func index(_ elapsed: TimeInterval, durations: [TimeInterval]) -> Int {
        var remaining = elapsed
        for (index, duration) in durations.enumerated() {
            if remaining < duration { return index }
            remaining -= duration
        }
        return durations.count - 1
    }

    private func makePanel() -> PetPanel {
        let view = PetCanvas(controller: self)
        let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 216, height: 203),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Mivori 奶蛙"
        panel.identifier = NSUserInterfaceItemIdentifier("mivori.pet.window")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        floating = panel
        canvas = view
        return panel
    }

    private func place(_ panel: PetPanel) {
        if let position = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double], position.count == 2 {
            let point = NSPoint(x: position[0], y: position[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: point, size: panel.frame.size)) }) {
                panel.setFrameOrigin(point)
                return
            }
        }
        guard let available = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: available.maxX - panel.frame.width - 24, y: available.minY + 28))
    }

    fileprivate func rememberPosition(_ window: NSWindow) {
        UserDefaults.standard.set([Double(window.frame.minX), Double(window.frame.minY)], forKey: Self.positionKey)
    }
}

@MainActor
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private enum PetArt {
    static let frames: [[CGImage]] = {
        guard let url = Bundle.main.url(forResource: "NaiWaAtlas", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return [7, 5, 3].enumerated().map { row, amount in
            (0..<amount).compactMap { col in
                sheet.cropping(to: CGRect(x: col * 192, y: row * 208, width: 192, height: 208))
            }
        }
    }()

    static func image(row: Int, index: Int) -> CGImage? {
        guard frames.indices.contains(row), frames[row].indices.contains(index) else { return nil }
        return frames[row][index]
    }
}

@MainActor
private final class PetCanvas: NSView {
    private unowned let controller: MivoriDesktopPet
    private var pressPoint: NSPoint?
    private var pressOrigin = NSPoint.zero
    private var dragging = false

    init(controller: MivoriDesktopPet) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("桌面奶蛙")
        setAccessibilityHelp("单击播放笑声表情，拖动移动。")
        setAccessibilityIdentifier("mivori.pet.sprite")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        controller.laugh()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let state = controller.frame(now: ProcessInfo.processInfo.systemUptime)
        if let image = PetArt.image(row: state.row, index: state.index),
           let graphics = NSGraphicsContext.current?.cgContext {
            graphics.saveGState()
            graphics.interpolationQuality = .none
            graphics.draw(image, in: CGRect(x: (bounds.width - 153) / 2, y: 3, width: 153, height: 166))
            graphics.restoreGState()
        }
        if state.laughing {
            let bubble = CGRect(x: (bounds.width - 84) / 2, y: 169, width: 84, height: 28)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 9, yRadius: 9).fill()
            let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let label = "破崩了" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: bubble.midX - size.width / 2, y: bubble.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        pressPoint = NSEvent.mouseLocation
        pressOrigin = window.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let pressPoint else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - pressPoint.x
        let dy = point.y - pressPoint.y
        if !dragging && abs(dx) + abs(dy) < 5 { return }
        if !dragging { controller.setDragging(true) }
        dragging = true
        var origin = NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(visible.minX, origin.x), max(visible.minX, visible.maxX - window.frame.width))
            origin.y = min(max(visible.minY, origin.y), max(visible.minY, visible.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; dragging = false }
        guard pressPoint != nil else { return }
        if dragging {
            controller.setDragging(false)
            if let window { controller.rememberPosition(window) }
        } else {
            controller.laugh()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开桌宠页", action: #selector(openPetPage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "隐藏奶蛙", action: #selector(hidePet), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openPetPage() {
        AppDelegate.shared?.showMainWindow()
        NotificationCenter.default.post(name: .openMivoriDesktopPet, object: nil)
    }
    @objc private func hidePet() { controller.setVisible(false) }
}

@MainActor
struct MivoriDesktopPetView: View {
    @ObservedObject private var pet = MivoriDesktopPet.shared
    @Environment(\.mainTopBarContentPadding) private var mainTopBarContentPadding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("桌面奶蛙").font(.largeTitle.bold())
                HStack(spacing: 28) {
                    TimelineView(.animation(minimumInterval: 1 / 20)) { _ in
                        let state = pet.frame(now: ProcessInfo.processInfo.systemUptime)
                        VStack(spacing: 7) {
                            Text("破崩了").font(.headline).opacity(state.laughing ? 1 : 0)
                            if let frame = PetArt.image(row: state.row, index: state.index) {
                                Image(frame, scale: 1, label: Text("奶蛙"))
                                    .interpolation(.none).resizable().scaledToFit()
                                    .frame(width: 170, height: 184)
                            }
                        }
                        .frame(width: 235, height: 245)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("显示桌面奶蛙", isOn: Binding(get: { pet.isVisible }, set: { pet.setVisible($0) }))
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("mivori.pet.visible")
                        Button("预览捧腹笑") { pet.laugh() }
                            .accessibilityIdentifier("mivori.pet.laugh")
                        Text("点击奶蛙看它捧腹笑，按住拖动换位置。右键可隐藏桌宠。")
                            .foregroundStyle(.secondary)
                        Link("奶蛙像素素材 · Maple498 · CC BY 4.0",
                             destination: URL(string: "https://github.com/Maple498/nai-wa-codex-pet")!)
                            .font(.caption)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 840, alignment: .leading)
        }
        .safeAreaPadding(.top, mainTopBarContentPadding)
        .accessibilityIdentifier("mivori.pet.page")
    }
}
