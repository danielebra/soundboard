import AppKit
import QuartzCore

/// Watches for the pointer resting in a screen corner. Mouse-moved monitors need no
/// Accessibility permission (only key monitors do). A short dwell keeps a quick pass or a
/// click at the corner (the Apple menu, the clock) from opening the palette.
final class CornerTrigger {
    var corner: HotCorner = .off {
        didSet { if corner != oldValue { install() } }
    }
    /// While the palette is open the corner does nothing.
    var isSuspended = false
    var onTrigger: ((NSScreen) -> Void)?

    private var monitors: [Any] = []
    private var dwell: Timer?
    /// Cleared when the corner fires, and set again once the pointer leaves it, so resting
    /// there after the palette closes doesn't reopen it.
    private var armed = true

    private func install() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        dwell?.invalidate()
        dwell = nil
        guard corner != .off else { return }
        // Global monitors only see events sent to other apps; the local one covers ours.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.moved() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.moved()
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func moved() {
        guard screen(at: NSEvent.mouseLocation) != nil else {
            armed = true
            dwell?.invalidate()
            dwell = nil
            return
        }
        guard armed, dwell == nil, !isSuspended else { return }
        dwell = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dwell = nil
            guard !self.isSuspended, let screen = self.screen(at: NSEvent.mouseLocation) else { return }
            self.armed = false
            self.onTrigger?(screen)
        }
    }

    /// The screen whose corner the pointer is in. A corner that touches another display
    /// doesn't count: the pointer passes through it instead of stopping there.
    private func screen(at point: NSPoint) -> NSScreen? {
        guard corner != .off else { return nil }
        let screens = NSScreen.screens
        return screens.first { screen in
            let c = corner.point(of: screen.frame)
            guard abs(point.x - c.x) <= 3, abs(point.y - c.y) <= 3 else { return false }
            let dx: CGFloat = corner.isRight ? 2 : -2, dy: CGFloat = corner.isTop ? 2 : -2
            let beyond = [NSPoint(x: c.x + dx, y: c.y - dy), NSPoint(x: c.x - dx, y: c.y + dy), NSPoint(x: c.x + dx, y: c.y + dy)]
            return !screens.contains { other in other != screen && beyond.contains { other.frame.contains($0) } }
        }
    }
}

/// A floating copy of the pad that fans out of a screen corner, so the soundboard works
/// without a Stream Deck. It's a non-activating panel: clicking a key never takes focus
/// from the call app. Keys behave like the deck's (Bleep plays while held).
final class Palette {
    private unowned let app: AppController
    private var panel: NSPanel?
    private var view: PaletteView?
    private var screenFrame = NSRect.zero
    private var corner: HotCorner = .topRight
    private var watch: Timer?
    private var clickMonitor: Any?
    private var entered = false
    private var stays = false
    private var outsideSince: Date?
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    /// Gap between the screen corner and the palette.
    private static let margin: CGFloat = 4

    init(app: AppController) {
        self.app = app
    }

    /// Opens the palette in `corner` of `screen`. It closes when the pointer leaves it or you
    /// click elsewhere; `stays` keeps it open until the pointer has been in it at least once.
    func show(on screen: NSScreen?, corner: HotCorner, stays: Bool = false) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let (panel, view) = makePanel()
        screenFrame = screen.frame
        self.corner = corner == .off ? .topRight : corner
        self.stays = stays
        entered = false
        outsideSince = nil
        view.corner = self.corner
        view.scale = screen.backingScaleFactor
        isVisible = true
        update()
        panel.orderFrontRegardless()
        view.fanOut()

        watch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkPointer() }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
        if clickMonitor == nil {
            // Global: only clicks that went to other apps, i.e. outside the palette.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
        onVisibilityChange?(true)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        watch?.invalidate()
        watch = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        view?.releasePress()
        view?.fold { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
        }
        onVisibilityChange?(false)
    }

    func toggle(corner: HotCorner) {
        if isVisible { hide() } else { show(on: nil, corner: corner, stays: true) }
    }

    /// Redraws every key (config, page or layout changed).
    func reload() {
        if isVisible { update() }
    }

    /// Redraws one key of the current page (it started or stopped playing).
    func refresh(index: Int) {
        guard isVisible, let view, index < view.layout.keys else { return }
        view.setImage(index, image(index))
    }

    private func update() {
        guard let panel, let view else { return }
        let keys = app.keyLayout
        let layout = PaletteView.Layout(keys: keys.keys, columns: keys.columns,
                                        pages: max(1, app.config.pages.count), page: app.page)
        view.apply(layout, images: (0..<layout.keys).map(image))
        // The plate sits `margin` from the corner; the window extends past it for the shadow.
        let plate = view.plateSize
        let c = corner.point(of: screenFrame)
        let x = corner.isRight ? c.x - Self.margin - plate.width : c.x + Self.margin
        let y = corner.isTop ? c.y - Self.margin - plate.height : c.y + Self.margin
        let s = PaletteView.shadow
        panel.setFrame(NSRect(x: x - s, y: y - s, width: plate.width + 2 * s, height: plate.height + 2 * s), display: true)
    }

    private func image(_ index: Int) -> CGImage {
        let size = Int((PaletteView.key * (view?.scale ?? 2)).rounded())
        return app.renderKey(page: app.page, index: index, size: size)
    }

    /// Closes once the pointer has been away for a moment (never while a key is held).
    private func checkPointer() {
        guard let panel, let view else { return }
        let s = PaletteView.shadow
        let plate = panel.frame.insetBy(dx: s, dy: s)
        if plate.insetBy(dx: -Self.margin - 6, dy: -Self.margin - 6).contains(NSEvent.mouseLocation) || view.isPressing {
            entered = true
            outsideSince = nil
            return
        }
        if stays && !entered { return }
        let since = outsideSince ?? Date()
        outsideSince = since
        // Coming from the corner, the pointer gets a moment to find its way in.
        if Date().timeIntervalSince(since) >= (entered ? 0.35 : 1.5) { hide() }
    }

    private func makePanel() -> (NSPanel, PaletteView) {
        if let panel, let view { return (panel, view) }
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu // above the menu bar, so a top corner works too
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the plate draws its own, so it follows the fan-out
        panel.isReleasedWhenClosed = false
        let view = PaletteView(frame: panel.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        view.onPress = { [weak self] index, pressed in self?.app.press(index: index, pressed: pressed) }
        view.onTurn = { [weak self] delta in self?.app.turnPage(by: delta) }
        panel.contentView = view
        self.panel = panel
        self.view = view
        return (panel, view)
    }

    /// The palette as a PNG (for `--snapshot`).
    func snapshotPNG() -> Data? {
        guard isVisible, let view, let layer = view.layer else { return nil }
        let scale = view.scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return rep.representation(using: .png, properties: [:])
    }
}

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The palette's content: a dark plate like the deck's face, the keys, and a page switcher
/// when there's more than one page. Everything is a layer so it can fly out of the corner.
private final class PaletteView: NSView {
    struct Layout: Equatable {
        var keys: Int
        var columns: Int
        var pages: Int
        var page: Int
        var rows: Int { (keys + columns - 1) / columns }
    }

    private enum Target: Equatable {
        case key(Int), back, forward
    }

    static let key: CGFloat = 64
    static let gap: CGFloat = 8
    static let inset: CGFloat = 10
    static let footer: CGFloat = 28
    /// Room around the plate for its shadow.
    static let shadow: CGFloat = 20

    var onPress: ((Int, Bool) -> Void)?
    var onTurn: ((Int) -> Void)?
    var corner: HotCorner = .topRight
    var scale: CGFloat = 2 {
        didSet { allLayers.forEach { $0.contentsScale = scale } }
    }
    private(set) var layout = Layout(keys: 0, columns: 1, pages: 1, page: 0)
    private let root = CALayer()
    private let plate = CALayer()
    private var keyLayers: [CALayer] = []
    private let pageText = CATextLayer()
    private let back = CATextLayer()
    private let forward = CATextLayer()
    private var hovered: Target?
    private var pressed: Target?
    var isPressing: Bool { pressed != nil }

    private var allLayers: [CALayer] { [plate, pageText, back, forward] + keyLayers }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root // layer-hosting: the view never redraws them itself
        wantsLayer = true
        plate.backgroundColor = CGColor(gray: 0.08, alpha: 0.96)
        plate.borderColor = CGColor(gray: 1, alpha: 0.12)
        plate.borderWidth = 1
        plate.cornerRadius = 16
        plate.shadowColor = CGColor(gray: 0, alpha: 1)
        plate.shadowOpacity = 0.45
        plate.shadowRadius = 12
        plate.shadowOffset = CGSize(width: 0, height: -4)
        root.addSublayer(plate)
        for (text, layer) in [("", pageText), ("‹", back), ("›", forward)] {
            layer.string = text
            layer.alignmentMode = .center
            layer.foregroundColor = CGColor(gray: 1, alpha: 0.7)
            layer.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            layer.fontSize = layer === pageText ? 11 : 20
            root.addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var plateSize: NSSize {
        let columns = CGFloat(layout.columns), rows = CGFloat(layout.rows)
        return NSSize(width: 2 * Self.inset + columns * Self.key + (columns - 1) * Self.gap,
                      height: 2 * Self.inset + rows * Self.key + (rows - 1) * Self.gap + (layout.pages > 1 ? Self.footer : 0))
    }

    func apply(_ newLayout: Layout, images: [CGImage]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let old = layout
        layout = newLayout
        if old.keys != newLayout.keys || old.columns != newLayout.columns || old.pages != newLayout.pages {
            arrange()
        }
        pageText.string = "Page \(newLayout.page + 1) of \(newLayout.pages)"
        for (layer, image) in zip(keyLayers, images) { layer.contents = image }
        CATransaction.commit()
    }

    func setImage(_ index: Int, _ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyLayers[safe: index]?.contents = image
        CATransaction.commit()
    }

    /// Lays the plate and keys out for the current layout, in the window's size for it.
    private func arrange() {
        while keyLayers.count < layout.keys {
            let key = CALayer()
            key.cornerRadius = 10
            key.masksToBounds = true
            key.borderColor = CGColor(gray: 1, alpha: 0.9)
            key.contentsGravity = .resizeAspectFill
            key.contentsScale = scale
            root.addSublayer(key)
            keyLayers.append(key)
        }
        while keyLayers.count > layout.keys { keyLayers.removeLast().removeFromSuperlayer() }

        let size = plateSize
        let s = Self.shadow
        plate.frame = CGRect(x: s, y: s, width: size.width, height: size.height)
        plate.shadowPath = CGPath(roundedRect: plate.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        let top = s + size.height - Self.inset
        for (i, key) in keyLayers.enumerated() {
            let row = CGFloat(i / layout.columns), column = CGFloat(i % layout.columns)
            key.frame = CGRect(x: s + Self.inset + column * (Self.key + Self.gap),
                               y: top - (row + 1) * Self.key - row * Self.gap, width: Self.key, height: Self.key)
        }
        let footer = layout.pages > 1
        for layer in [pageText, back, forward] { layer.isHidden = !footer }
        let y = s + Self.inset - 2
        pageText.frame = CGRect(x: s, y: y, width: size.width, height: 16)
        back.frame = CGRect(x: s + Self.inset, y: y - 6, width: 36, height: 26)
        forward.frame = CGRect(x: s + size.width - Self.inset - 36, y: y - 6, width: 36, height: 26)
        hovered = nil
        updateHighlights()
    }

    // MARK: Animation

    /// Where the plate's outer corner is, in this view.
    private var cornerPoint: CGPoint { corner.point(of: plate.frame) }

    private var animatedLayers: [CALayer] {
        ([pageText, back, forward].filter { !$0.isHidden } + keyLayers)
            .sorted { distance($0.position, cornerPoint) < distance($1.position, cornerPoint) }
    }

    /// The transform that tucks a layer into the corner.
    private func tucked(_ layer: CALayer) -> CATransform3D {
        let c = cornerPoint
        let offset = CATransform3DMakeTranslation((c.x - layer.position.x) * 0.85, (c.y - layer.position.y) * 0.85, 0)
        return CATransform3DScale(offset, 0.2, 0.2, 1)
    }

    /// The plate grows out of the corner and the keys follow, nearest first, with a little overshoot.
    func fanOut() {
        let now = CACurrentMediaTime()
        let springy = CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.55, 1)
        allLayers.forEach { $0.removeAllAnimations() }
        setPlateAnchor()

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DMakeScale(0.15, 0.15, 1)
        grow.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let plateGroup = CAAnimationGroup()
        plateGroup.animations = [grow, fade]
        plateGroup.duration = 0.26
        plateGroup.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.4, 1)
        plate.add(plateGroup, forKey: "fan")

        for (rank, layer) in animatedLayers.enumerated() {
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = tucked(layer)
            move.toValue = layer.transform
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.3
            group.timingFunction = springy
            group.beginTime = now + 0.03 + Double(rank) * 0.022
            group.fillMode = .backwards
            layer.add(group, forKey: "fan")
        }
    }

    /// The reverse of `fanOut`, quicker, then `completion`.
    func fold(completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        func add(_ layer: CALayer, to transform: CATransform3D, duration: Double) {
            let move = CABasicAnimation(keyPath: "transform")
            move.toValue = transform
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "fan")
        }
        for layer in animatedLayers { add(layer, to: tucked(layer), duration: 0.14) }
        add(plate, to: CATransform3DMakeScale(0.15, 0.15, 1), duration: 0.16)
        CATransaction.commit()
    }

    /// Scales the plate about the screen corner.
    private func setPlateAnchor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = plate.frame
        plate.anchorPoint = CGPoint(x: corner.isRight ? 1 : 0, y: corner.isTop ? 1 : 0)
        plate.frame = frame
        CATransaction.commit()
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func target(at event: NSEvent) -> Target? {
        let p = convert(event.locationInWindow, from: nil)
        if let i = keyLayers.firstIndex(where: { $0.frame.contains(p) }) { return .key(i) }
        guard layout.pages > 1 else { return nil }
        if back.frame.insetBy(dx: -6, dy: -4).contains(p) { return .back }
        if forward.frame.insetBy(dx: -6, dy: -4).contains(p) { return .forward }
        return nil
    }

    override func mouseMoved(with event: NSEvent) { hover(target(at: event)) }
    override func mouseEntered(with event: NSEvent) { hover(target(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ target: Target?) {
        guard target != hovered else { return }
        hovered = target
        updateHighlights()
    }

    override func mouseDown(with event: NSEvent) {
        guard let target = target(at: event) else { return }
        pressed = target
        switch target {
        case let .key(i): onPress?(i, true)
        case .back: onTurn?(-1)
        case .forward: onTurn?(1)
        }
        updateHighlights()
    }

    override func mouseUp(with event: NSEvent) { releasePress() }

    /// Ends a held key (Bleep stops on release).
    func releasePress() {
        guard let pressed else { return }
        self.pressed = nil
        if case let .key(i) = pressed { onPress?(i, false) }
        updateHighlights()
    }

    private func updateHighlights() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        for (i, layer) in keyLayers.enumerated() {
            let isPressed = pressed == .key(i), isHovered = hovered == .key(i)
            layer.transform = isPressed ? CATransform3DMakeScale(0.92, 0.92, 1)
                : isHovered ? CATransform3DMakeScale(1.05, 1.05, 1) : CATransform3DIdentity
            layer.borderWidth = isHovered && !isPressed ? 1.5 : 0
        }
        for (target, layer) in [(Target.back, back), (.forward, forward)] {
            layer.foregroundColor = CGColor(gray: 1, alpha: hovered == target ? 1 : 0.7)
        }
        CATransaction.commit()
    }
}
