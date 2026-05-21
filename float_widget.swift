// Floating Claude.ai usage widget — compact single-pane layout patterned
// after the official claude.ai billing page. Build via ./build_app.sh.

import Cocoa

// MARK: - Settings

enum Theme: String, CaseIterable {
    case system, dark, light

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var material: NSVisualEffectView.Material { .popover }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

enum ViewMode: String, CaseIterable {
    case full, compact
}

struct RefreshChoice {
    static let options: [(label: String, seconds: TimeInterval)] = [
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("30 min", 1800),
    ]
}

struct OpacityChoice {
    static let options: [(label: String, value: Double)] = [
        ("50%", 0.50),
        ("65%", 0.65),
        ("80%", 0.80),
        ("100%", 1.00),
    ]
}

enum Settings {
    private static let themeKey = "theme"
    private static let intervalKey = "refreshInterval"
    private static let originKey = "windowOrigin"
    private static let pinKey = "alwaysOnTop"
    private static let opacityKey = "opacity"
    private static let modeKey = "viewMode"

    static var viewMode: ViewMode {
        get { ViewMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .full }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var theme: Theme {
        get { Theme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }

    static var refreshInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: intervalKey)
            return v > 0 ? v : 300
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    static var alwaysOnTop: Bool {
        get {
            if UserDefaults.standard.object(forKey: pinKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: pinKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: pinKey) }
    }

    static var opacity: Double {
        get {
            let v = UserDefaults.standard.double(forKey: opacityKey)
            return v > 0 ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: opacityKey) }
    }

    static var savedOrigin: NSPoint? {
        get {
            guard let s = UserDefaults.standard.string(forKey: originKey) else { return nil }
            let p = NSPointFromString(s)
            return (p.x == 0 && p.y == 0) ? nil : p
        }
        set {
            if let p = newValue {
                UserDefaults.standard.set(NSStringFromPoint(p), forKey: originKey)
            }
        }
    }
}

// MARK: - Colors

func tierColor(forUtilization pct: Double?) -> NSColor {
    guard let v = pct else { return .systemGray }
    if v >= 90 { return .systemRed }
    if v >= 75 { return .systemYellow }
    return .systemGreen
}

let barBackgroundColor: NSColor = NSColor(
    name: nil,
    dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(white: 0.30, alpha: 1.0) : NSColor(white: 0.89, alpha: 1.0)
    })

// MARK: - Data

struct Usage {
    struct Bucket {
        let pct: Double?
        let resetsAt: Date?
    }

    let fiveHour: Bucket
    let sevenDay: Bucket
    let sevenDaySonnet: Bucket
    let sevenDayOpus: Bucket
    let sevenDayOAuth: Bucket

    static func parse(_ data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtNoFrac = ISO8601DateFormatter()
        fmtNoFrac.formatOptions = [.withInternetDateTime]

        func bucket(_ key: String) -> Bucket {
            let sub = obj[key] as? [String: Any]
            let pct = (sub?["utilization"] as? NSNumber)?.doubleValue
            var resetsAt: Date? = nil
            if let s = sub?["resets_at"] as? String {
                resetsAt = fmt.date(from: s) ?? fmtNoFrac.date(from: s)
            }
            return Bucket(pct: pct, resetsAt: resetsAt)
        }

        return Usage(
            fiveHour: bucket("five_hour"),
            sevenDay: bucket("seven_day"),
            sevenDaySonnet: bucket("seven_day_sonnet"),
            sevenDayOpus: bucket("seven_day_opus"),
            sevenDayOAuth: bucket("seven_day_oauth_apps"))
    }
}

func formatCountdown(_ resetDate: Date?) -> String {
    guard let date = resetDate else { return "—" }
    let interval = date.timeIntervalSinceNow
    if interval <= 0 { return "now" }
    let totalMinutes = Int(interval / 60)
    let hours = totalMinutes / 60
    let mins = totalMinutes % 60
    if hours == 0 { return "\(mins)m" }
    if hours >= 24 {
        let days = hours / 24
        return "\(days)d\(hours % 24)h"
    }
    return "\(hours)h\(mins)m"
}

func resolveScriptPath() -> String {
    // 1. Inside .app bundle (production install).
    if let res = Bundle.main.resourcePath {
        let bundled = res + "/poc_fetch_usage.py"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
    }
    // 2. Env override.
    if let p = ProcessInfo.processInfo.environment["CLAUDE_USAGE_SCRIPT"] { return p }
    // 3. CLI argument.
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    // 4. Dev fallback: current working directory (running raw binary from repo root).
    let cwd = FileManager.default.currentDirectoryPath + "/poc_fetch_usage.py"
    if FileManager.default.fileExists(atPath: cwd) { return cwd }
    return "poc_fetch_usage.py"
}
let scriptPath = resolveScriptPath()

func fetchUsage(completion: @escaping (Usage?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["python3", scriptPath]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let usage = task.terminationStatus == 0 ? Usage.parse(data) : nil
            DispatchQueue.main.async { completion(usage) }
        } catch {
            DispatchQueue.main.async { completion(nil) }
        }
    }
}

// MARK: - Progress bar

final class ProgressBar: NSView {
    var value: Double? = nil { didSet { needsDisplay = true } }
    var fillColor: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        barBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard let v = value else { return }
        let clamped = max(0, min(100, v))
        let proportional = bounds.width * CGFloat(clamped / 100.0)
        let actualWidth = max(proportional, bounds.height)
        let fillRect = NSRect(x: 0, y: 0, width: actualWidth, height: bounds.height)
        fillColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Metric block

final class MetricBlock {
    enum Layout { case full, compact }

    let name: String
    let layout: Layout
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleIcon = NSImageView()
    let subtitleLabel = NSTextField(labelWithString: "")
    let bar = ProgressBar()
    let pctLabel = NSTextField(labelWithString: "")
    let view: NSStackView

    private(set) var lastResetsAt: Date?

    init(name: String, layout: Layout) {
        self.name = name
        self.layout = layout

        titleLabel.stringValue = name
        titleLabel.textColor = .labelColor
        titleLabel.font =
            layout == .full
            ? .systemFont(ofSize: 11, weight: .semibold)
            : .systemFont(ofSize: 10, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let iconCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        subtitleIcon.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "resets in"
        )?.withSymbolConfiguration(iconCfg)
        subtitleIcon.contentTintColor = .tertiaryLabelColor
        subtitleIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subtitleIcon.widthAnchor.constraint(equalToConstant: 8),
            subtitleIcon.heightAnchor.constraint(equalToConstant: 8),
        ])

        pctLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        pctLabel.textColor = .secondaryLabelColor
        pctLabel.alignment = .right

        bar.translatesAutoresizingMaskIntoConstraints = false
        pctLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 56),
            bar.heightAnchor.constraint(equalToConstant: 4),
            pctLabel.widthAnchor.constraint(equalToConstant: 26),
        ])

        let leftGroup: NSView
        if layout == .full {
            let subtitleStack = NSStackView(views: [subtitleIcon, subtitleLabel])
            subtitleStack.orientation = .horizontal
            subtitleStack.alignment = .centerY
            subtitleStack.spacing = 2
            let vstack = NSStackView(views: [titleLabel, subtitleStack])
            vstack.orientation = .vertical
            vstack.alignment = .leading
            vstack.spacing = 1
            leftGroup = vstack
        } else {
            leftGroup = titleLabel
        }
        leftGroup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leftGroup.widthAnchor.constraint(equalToConstant: 60),
        ])

        view = NSStackView(views: [leftGroup, bar, pctLabel])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 5
    }

    func update(_ bucket: Usage.Bucket) {
        lastResetsAt = bucket.resetsAt
        let color = tierColor(forUtilization: bucket.pct)
        bar.fillColor = color
        bar.value = bucket.pct
        if let v = bucket.pct {
            pctLabel.stringValue = String(format: "%.0f%%", v)
            pctLabel.textColor = (v < 75) ? .secondaryLabelColor : color
        } else {
            pctLabel.stringValue = "—"
            pctLabel.textColor = .secondaryLabelColor
        }
        refreshCountdown()
    }

    func refreshCountdown() {
        guard layout == .full else { return }
        if let r = lastResetsAt {
            subtitleLabel.stringValue = formatCountdown(r)
            subtitleIcon.isHidden = false
        } else {
            subtitleLabel.stringValue = "—"
            subtitleIcon.isHidden = true
        }
    }

    func showError() {
        bar.value = nil
        pctLabel.stringValue = "—"
        pctLabel.textColor = .secondaryLabelColor
        if layout == .full {
            subtitleLabel.stringValue = "error"
            subtitleIcon.isHidden = true
        }
    }
}

// MARK: - Window

final class FloatingPanel: NSPanel {
    init() {
        let size = NSSize(width: 170, height: 158)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = Settings.alwaysOnTop ? .floating : .normal
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let origin = Settings.savedOrigin {
            setFrameOrigin(origin)
        } else if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(
                NSPoint(
                    x: visible.maxX - size.width - 16,
                    y: visible.maxY - size.height - 16))
        }
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - Content view

final class ContentView: NSView {
    let fiveHourBlock = MetricBlock(name: "5-hour", layout: .full)
    let sevenDayBlock = MetricBlock(name: "All models", layout: .full)
    let sonnetBlock = MetricBlock(name: "Sonnet", layout: .compact)
    let opusBlock = MetricBlock(name: "Opus", layout: .compact)
    let oauthBlock = MetricBlock(name: "Apps", layout: .compact)
    let planUsageHeader = ContentView.makeSectionHeader("PLAN")
    let weeklyHeader = ContentView.makeSectionHeader("WEEKLY")

    weak var appDelegate: AppDelegate?
    private let blur = NSVisualEffectView()
    private let mainStack = NSStackView()

    static func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 8, weight: .bold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        blur.frame = bounds
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 3
        mainStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        mainStack.addArrangedSubview(planUsageHeader)
        mainStack.addArrangedSubview(fiveHourBlock.view)
        mainStack.addArrangedSubview(weeklyHeader)
        mainStack.addArrangedSubview(sevenDayBlock.view)
        mainStack.addArrangedSubview(sonnetBlock.view)
        mainStack.addArrangedSubview(opusBlock.view)
        mainStack.addArrangedSubview(oauthBlock.view)

        mainStack.setCustomSpacing(2, after: planUsageHeader)
        mainStack.setCustomSpacing(8, after: fiveHourBlock.view)
        mainStack.setCustomSpacing(2, after: weeklyHeader)
        mainStack.setCustomSpacing(5, after: sevenDayBlock.view)
        mainStack.setCustomSpacing(3, after: sonnetBlock.view)
        mainStack.setCustomSpacing(3, after: opusBlock.view)

        applyTheme(Settings.theme)
        applyOpacity(Settings.opacity)
        applyMode(Settings.viewMode)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: Theme) {
        blur.material = theme.material
        appearance = theme.appearance
        window?.appearance = theme.appearance
    }

    func applyMode(_ mode: ViewMode) {
        let compact = (mode == .compact)
        // Compact mode hides everything except the 5-hour block, no headers.
        planUsageHeader.isHidden = compact
        weeklyHeader.isHidden = compact
        sevenDayBlock.view.isHidden = compact
        sonnetBlock.view.isHidden = compact
        opusBlock.view.isHidden = compact
        oauthBlock.view.isHidden = compact
    }

    func applyOpacity(_ value: Double) {
        // Only fade the frosted-glass background — keep bar + text fully
        // opaque so they remain readable at low opacity.
        blur.alphaValue = CGFloat(value)
        layer?.borderColor =
            NSColor.separatorColor.withAlphaComponent(0.4 * value).cgColor
    }

    func update(_ usage: Usage?) {
        guard let u = usage else {
            [fiveHourBlock, sevenDayBlock, sonnetBlock, opusBlock, oauthBlock].forEach {
                $0.showError()
            }
            return
        }
        fiveHourBlock.update(u.fiveHour)
        sevenDayBlock.update(u.sevenDay)
        sonnetBlock.update(u.sevenDaySonnet)
        opusBlock.update(u.sevenDayOpus)
        oauthBlock.update(u.sevenDayOAuth)
    }

    func tickCountdowns() {
        [fiveHourBlock, sevenDayBlock].forEach { $0.refreshCountdown() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let d = appDelegate else { return }
        let menu = NSMenu()

        let refreshNow = NSMenuItem(
            title: "Refresh Now", action: #selector(AppDelegate.refresh), keyEquivalent: "r")
        refreshNow.target = d
        menu.addItem(refreshNow)

        let open = NSMenuItem(
            title: "Open Claude.ai", action: #selector(AppDelegate.openClaude), keyEquivalent: "")
        open.target = d
        menu.addItem(open)

        menu.addItem(.separator())

        let pin = NSMenuItem(
            title: "Always on Top", action: #selector(AppDelegate.toggleAlwaysOnTop),
            keyEquivalent: "")
        pin.target = d
        pin.state = Settings.alwaysOnTop ? .on : .off
        menu.addItem(pin)

        let compact = NSMenuItem(
            title: "Compact View", action: #selector(AppDelegate.toggleCompact),
            keyEquivalent: "")
        compact.target = d
        compact.state = Settings.viewMode == .compact ? .on : .off
        menu.addItem(compact)

        menu.addItem(themeSubmenu(target: d))
        menu.addItem(opacitySubmenu(target: d))
        menu.addItem(intervalSubmenu(target: d))

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func themeSubmenu(target: AppDelegate) -> NSMenuItem {
        let parent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in Theme.allCases {
            let item = NSMenuItem(
                title: t.displayName, action: #selector(AppDelegate.setTheme(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = t.rawValue
            item.state = (Settings.theme == t) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func opacitySubmenu(target: AppDelegate) -> NSMenuItem {
        let parent = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for opt in OpacityChoice.options {
            let item = NSMenuItem(
                title: opt.label, action: #selector(AppDelegate.setOpacity(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = opt.value
            item.state = abs(Settings.opacity - opt.value) < 0.01 ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func intervalSubmenu(target: AppDelegate) -> NSMenuItem {
        let parent = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for opt in RefreshChoice.options {
            let item = NSMenuItem(
                title: opt.label, action: #selector(AppDelegate.setInterval(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = opt.seconds
            item.state = (Settings.refreshInterval == opt.seconds) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var content: ContentView!
    var fetchTimer: Timer?
    var countdownTimer: Timer?

    private let fullHeight: CGFloat = 158
    private let compactHeight: CGFloat = 42
    private let windowWidth: CGFloat = 170

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel = FloatingPanel()
        content = ContentView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.appDelegate = self
        panel.contentView = content
        content.applyTheme(Settings.theme)
        content.applyOpacity(Settings.opacity)
        sizeWindow(for: Settings.viewMode, animate: false)
        panel.orderFront(nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowMoved(_:)),
            name: NSWindow.didMoveNotification, object: panel)

        refresh()
        restartFetchTimer()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            self?.content.tickCountdowns()
        }
    }

    @objc func windowMoved(_ notification: Notification) {
        Settings.savedOrigin = panel.frame.origin
    }

    func restartFetchTimer() {
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(
            withTimeInterval: Settings.refreshInterval, repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        fetchUsage { [weak self] usage in
            self?.content.update(usage)
        }
    }

    @objc func openClaude() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func toggleAlwaysOnTop() {
        let on = !Settings.alwaysOnTop
        Settings.alwaysOnTop = on
        panel.level = on ? .floating : .normal
    }

    @objc func toggleCompact() {
        let next: ViewMode = Settings.viewMode == .full ? .compact : .full
        Settings.viewMode = next
        content.applyMode(next)
        sizeWindow(for: next, animate: true)
    }

    func sizeWindow(for mode: ViewMode, animate: Bool) {
        let target = NSSize(
            width: windowWidth, height: mode == .compact ? compactHeight : fullHeight)
        // Anchor the top edge so visual top stays put when resizing.
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.minX, y: frame.maxY - target.height,
            width: target.width, height: target.height)
        panel.setFrame(newFrame, display: true, animate: animate)
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = Theme(rawValue: raw)
        else { return }
        Settings.theme = theme
        content.applyTheme(theme)
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        Settings.refreshInterval = interval
        restartFetchTimer()
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.opacity = value
        content.applyOpacity(value)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
