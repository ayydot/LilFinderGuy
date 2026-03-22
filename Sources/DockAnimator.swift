import Cocoa
import AVFoundation
import CoreImage

// MARK: - Preferences

final class Preferences {
    static let shared = Preferences()
    private let ud = UserDefaults.standard
    private init() {}

    var bookmarks: [String] {
        get {
            if let b = ud.array(forKey: "LFG.bookmarks") as? [String] { return b }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return ["\(home)/Downloads", "\(home)/Desktop", "\(home)/Documents"]
        }
        set { ud.set(newValue, forKey: "LFG.bookmarks") }
    }

    var recents: [String] {
        get { ud.array(forKey: "LFG.recents") as? [String] ?? [] }
        set { ud.set(newValue, forKey: "LFG.recents") }
    }

    func addRecent(_ path: String) {
        var r = recents.filter { $0 != path }
        r.insert(path, at: 0)
        recents = Array(r.prefix(5))
    }

    enum Scale: String, CaseIterable {
        case small, medium, large
        var label: String { rawValue.capitalized }
        var factor: CGFloat {
            switch self { case .small: return 0.5; case .medium: return 0.75; case .large: return 1.0 }
        }
    }

    var scale: Scale {
        get { Scale(rawValue: ud.string(forKey: "LFG.scale") ?? "") ?? .large }
        set { ud.set(newValue.rawValue, forKey: "LFG.scale") }
    }
}

// MARK: - CharacterWindow

final class CharacterWindow: NSObject {

    private enum State { case idle, fallingAsleep, sleeping, wakingUp }

    // MARK: Window
    private var window: CharacterNSWindow!
    private weak var imageView: NSImageView?
    private weak var clickView: ClickableView?

    // MARK: Assets
    private var sittingPNG:  NSImage?
    private var sleepFrames: [NSImage] = []
    private var wakeFrames:  [NSImage] = []
    private var sleepFPS: Double = 30
    private var wakeFPS:  Double = 30

    // MARK: Animation state
    private var state:      State = .idle
    private var frameIndex: Int   = 0
    private var animTimer:  Timer?
    private var sleepTimer: Timer?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private lazy var greenCubeData: Data = Self.buildGreenScreenCube()

    private static let baseSize = CGSize(width: 400, height: 225)
    private var windowSize: CGSize {
        let f = Preferences.shared.scale.factor
        return CGSize(width: Self.baseSize.width * f, height: Self.baseSize.height * f)
    }

    // MARK: Init
    override init() {
        super.init()
        setupWindow()
        loadAssetsAsync()
    }

    // MARK: Window setup
    private func setupWindow() {
        guard let screen = NSScreen.main else { return }
        let sz  = windowSize
        let vfr = screen.visibleFrame
        let origin = CGPoint(x: vfr.maxX - sz.width - 20, y: vfr.minY + 20)

        let win = CharacterNSWindow(
            contentRect: CGRect(origin: origin, size: sz),
            styleMask: .borderless, backing: .buffered, defer: false)
        win.level            = .floating
        win.backgroundColor  = .clear
        win.isOpaque         = false
        win.hasShadow        = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let cv = ClickableView(frame: CGRect(origin: .zero, size: sz))
        cv.onClick      = { [weak self] in self?.handleClick() }
        cv.onDrop       = { [weak self] url in self?.openFolder(url) }
        cv.menuProvider = { [weak self] event in self?.buildMenu(for: event) ?? NSMenu() }
        win.contentView = cv
        clickView = cv

        let iv = NSImageView(frame: cv.bounds)
        iv.imageScaling    = .scaleProportionallyUpOrDown
        iv.imageAlignment  = .alignCenter
        iv.autoresizingMask = [.width, .height]
        cv.addSubview(iv)
        imageView = iv

        win.orderFrontRegardless()
        self.window = win
    }

    // MARK: Asset loading
    private func loadAssetsAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let png = Bundle.main.url(forResource: "LilFinder_Sitting_1", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
            var sleepFrames: [NSImage] = []; var sleepFPS: Double = 30
            var wakeFrames:  [NSImage] = []; var wakeFPS:  Double = 30
            if let url = Bundle.main.url(forResource: "LilFinder_Sleeps", withExtension: "mp4") {
                (sleepFrames, sleepFPS) = self.extractFrames(from: url)
            }
            if let url = Bundle.main.url(forResource: "LilFinder_Wakesup", withExtension: "mp4") {
                (wakeFrames, wakeFPS) = self.extractFrames(from: url)
            }
            DispatchQueue.main.async {
                self.sittingPNG  = png
                self.sleepFrames = sleepFrames; self.sleepFPS = sleepFPS
                self.wakeFrames  = wakeFrames;  self.wakeFPS  = wakeFPS
                self.showIdle()
            }
        }
    }

    // MARK: Frame decoding
    private func extractFrames(from url: URL) -> ([NSImage], Double) {
        let asset = AVURLAsset(url: url)
        let gen   = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform  = true
        gen.maximumSize = CGSize(width: Self.baseSize.width * 2, height: Self.baseSize.height * 2)
        gen.requestedTimeToleranceBefore    = .zero
        gen.requestedTimeToleranceAfter     = .zero
        let tracks = asset.tracks(withMediaType: .video)
        let rawFPS = Double(tracks.first?.nominalFrameRate ?? 0)
        let fps    = rawFPS > 1 ? rawFPS : 30.0
        let dur    = CMTimeGetSeconds(asset.duration)
        let count  = Int(ceil(dur * fps))
        NSLog("LilFinderGuy: loading %@ fps=%.0f frames=%d", url.lastPathComponent, fps, count)
        var frames = [NSImage](); frames.reserveCapacity(count)
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
            frames.append(chromaKey(cg) ?? NSImage(cgImage: cg, size: Self.baseSize))
        }
        NSLog("LilFinderGuy: loaded %d frames from %@", frames.count, url.lastPathComponent)
        return (frames, fps)
    }

    // MARK: Chroma key
    private func chromaKey(_ src: CGImage) -> NSImage? {
        let ci = CIImage(cgImage: src)
        guard let f = CIFilter(name: "CIColorCube") else { return nil }
        f.setValue(64,                      forKey: "inputCubeDimension")
        f.setValue(greenCubeData as NSData, forKey: "inputCubeData")
        f.setValue(ci,                      forKey: kCIInputImageKey)
        guard let out = f.outputImage,
              let cg  = ciContext.createCGImage(out, from: out.extent,
                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        else { return nil }
        return NSImage(cgImage: cg, size: Self.baseSize)
    }

    private static func buildGreenScreenCube() -> Data {
        let size = 64
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var i = 0
        for bIdx in 0..<size {
            for gIdx in 0..<size {
                for rIdx in 0..<size {
                    let r = Float(rIdx) / Float(size - 1)
                    let g = Float(gIdx) / Float(size - 1)
                    let b = Float(bIdx) / Float(size - 1)
                    let maxV = max(r, g, b), minV = min(r, g, b)
                    let delta = maxV - minV
                    var hue: Float = 0
                    if delta > 0.001 {
                        if maxV == g      { hue = 60 * ((b - r) / delta + 2) }
                        else if maxV == r { hue = 60 * ((g - b) / delta); if hue < 0 { hue += 360 } }
                        else              { hue = 60 * ((r - g) / delta + 4) }
                    }
                    if hue < 0 { hue += 360 }; if hue > 360 { hue -= 360 }
                    let sat = maxV > 0 ? delta / maxV : 0
                    let isGreen = hue >= 85 && hue <= 155 && sat > 0.20 && maxV > 0.10
                    let a: Float = isGreen ? 0 : 1
                    cube[i] = r*a; cube[i+1] = g*a; cube[i+2] = b*a; cube[i+3] = a; i += 4
                }
            }
        }
        return Data(bytes: cube, count: cube.count * MemoryLayout<Float>.size)
    }

    // MARK: State machine

    // Idle: hold the first frame of the sleep video (awake-seated pose).
    private func showIdle() {
        animTimer?.invalidate()
        sleepTimer?.invalidate()
        clickView?.clickOnDown = false
        state = .idle
        imageView?.image = sleepFrames.first ?? sittingPNG

        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.playSleepAnimation()
        }
        RunLoop.main.add(sleepTimer!, forMode: .common)
    }

    private func playSleepAnimation() {
        sleepTimer?.invalidate()
        animTimer?.invalidate()
        guard !sleepFrames.isEmpty else { return }
        clickView?.clickOnDown = true
        state = .fallingAsleep; frameIndex = 0
        imageView?.image = sleepFrames[0]
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / sleepFPS, repeats: true) { [weak self] _ in
            guard let self, case .fallingAsleep = self.state else { return }
            self.frameIndex += 1
            if self.frameIndex >= self.sleepFrames.count {
                self.animTimer?.invalidate()
                self.state = .sleeping
                self.imageView?.image = self.sleepFrames.last
            } else {
                self.imageView?.image = self.sleepFrames[self.frameIndex]
            }
        }
        RunLoop.main.add(animTimer!, forMode: .common)
    }

    private func playWakeAnimation(thenOpen folderURL: URL? = nil) {
        sleepTimer?.invalidate()
        animTimer?.invalidate()
        clickView?.clickOnDown = false
        let target = folderURL ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        // Open immediately — don't make the user wait for the animation
        NSWorkspace.shared.open(target)
        guard !wakeFrames.isEmpty else { showIdle(); return }
        state = .wakingUp; frameIndex = 0
        imageView?.image = wakeFrames[0]
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / wakeFPS, repeats: true) { [weak self] _ in
            guard let self, case .wakingUp = self.state else { return }
            self.frameIndex += 1
            if self.frameIndex >= self.wakeFrames.count {
                self.animTimer?.invalidate()
                self.showIdle()
            } else {
                self.imageView?.image = self.wakeFrames[self.frameIndex]
            }
        }
        RunLoop.main.add(animTimer!, forMode: .common)
    }

    // MARK: Interaction

    private func handleClick() {
        switch state {
        case .idle:
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        case .fallingAsleep, .sleeping:
            playWakeAnimation()
        case .wakingUp:
            break
        }
    }

    func openFolder(_ url: URL) {
        var target = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           !isDir.boolValue {
            target = url.deletingLastPathComponent()
        }
        Preferences.shared.addRecent(target.path)
        switch state {
        case .idle:
            NSWorkspace.shared.open(target)
        case .fallingAsleep, .sleeping:
            playWakeAnimation(thenOpen: target)
        default:
            NSWorkspace.shared.open(target)
        }
    }

    func promptAndOpen() {
        let alert = NSAlert()
        alert.messageText     = "Go to Folder"
        alert.informativeText = "Enter the path to open in Finder:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "e.g. ~/Downloads or /usr/local"
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            let err = NSAlert()
            err.messageText = "Folder not found"
            err.informativeText = "\"" + raw + "\" doesn't exist or isn't a folder."
            err.alertStyle = .warning; err.runModal(); return
        }
        openFolder(URL(fileURLWithPath: expanded))
    }

    // MARK: Window scaling
    func applyScale(_ scale: Preferences.Scale) {
        Preferences.shared.scale = scale
        let sz = windowSize
        guard let win = window else { return }
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        win.setFrame(CGRect(
            x: center.x - sz.width / 2, y: center.y - sz.height / 2,
            width: sz.width, height: sz.height), display: true, animate: true)
    }

    // MARK: Right-click menu
    func buildMenu(for event: NSEvent) -> NSMenu {
        let prefs = Preferences.shared
        let menu  = NSMenu()

        let gtf = NSMenuItem(title: "Go to Folder...",
            action: #selector(menuGoToFolder), keyEquivalent: "")
        gtf.target = self; menu.addItem(gtf)
        menu.addItem(.separator())

        let bmHeader = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bmHeader.isEnabled = false; menu.addItem(bmHeader)
        for path in prefs.bookmarks {
            let display = (path as NSString).abbreviatingWithTildeInPath
            let item = NSMenuItem(title: "  " + display,
                action: #selector(menuOpenBookmark(_:)), keyEquivalent: "")
            item.representedObject = path; item.target = self; menu.addItem(item)
        }
        let addBM = NSMenuItem(title: "  Add Bookmark...",
            action: #selector(menuAddBookmark), keyEquivalent: "")
        addBM.target = self; menu.addItem(addBM)
        menu.addItem(.separator())

        let recents = prefs.recents
        if !recents.isEmpty {
            let rh = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
            rh.isEnabled = false; menu.addItem(rh)
            for path in recents {
                let display = (path as NSString).abbreviatingWithTildeInPath
                let item = NSMenuItem(title: "  " + display,
                    action: #selector(menuOpenRecent(_:)), keyEquivalent: "")
                item.representedObject = path; item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let sizeHeader = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeHeader.isEnabled = false; menu.addItem(sizeHeader)
        for scale in Preferences.Scale.allCases {
            let item = NSMenuItem(title: "  " + scale.label,
                action: #selector(menuSetScale(_:)), keyEquivalent: "")
            item.representedObject = scale.rawValue
            item.state  = prefs.scale == scale ? .on : .off
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit LilFinderGuy",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func menuGoToFolder() { promptAndOpen() }

    @objc private func menuOpenBookmark(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        openFolder(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    @objc private func menuOpenRecent(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        openFolder(URL(fileURLWithPath: path))
    }

    @objc private func menuAddBookmark() {
        let alert = NSAlert()
        alert.messageText     = "Add Bookmark"
        alert.informativeText = "Enter the folder path to bookmark:"
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "e.g. ~/Projects"; field.bezelStyle = .roundedBezel
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            let err = NSAlert(); err.messageText = "Not a folder"; err.runModal(); return
        }
        var bm = Preferences.shared.bookmarks
        if !bm.contains(expanded) { bm.append(expanded); Preferences.shared.bookmarks = bm }
    }

    @objc private func menuSetScale(_ item: NSMenuItem) {
        guard let raw   = item.representedObject as? String,
              let scale = Preferences.Scale(rawValue: raw) else { return }
        applyScale(scale)
    }
}

// MARK: - CharacterNSWindow

private class CharacterNSWindow: NSWindow {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - ClickableView

private class ClickableView: NSView {
    var onClick:      (() -> Void)?
    var onDrop:       ((URL) -> Void)?
    var menuProvider: ((NSEvent) -> NSMenu)?
    var clickOnDown = false

    private var dragStartScreen: CGPoint = .zero
    private var dragStartOrigin: CGPoint = .zero
    private var didDrag     = false
    private var firedOnDown = false

    required init?(coder: NSCoder) { fatalError() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        registerForDraggedTypes([.fileURL])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        firedOnDown = false
        dragStartScreen = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        if clickOnDown { firedOnDown = true; onClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        guard let win = window else { return }
        let cur = NSEvent.mouseLocation
        win.setFrameOrigin(CGPoint(
            x: dragStartOrigin.x + cur.x - dragStartScreen.x,
            y: dragStartOrigin.y + cur.y - dragStartScreen.y))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag && !firedOnDown { onClick?() }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let menu = menuProvider?(event) else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: 0), in: self)
    }

    // MARK: Drag destination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderWidth  = 2
        layer?.borderColor  = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 8
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self],
                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else { return false }
        onDrop?(url)
        return true
    }
}
