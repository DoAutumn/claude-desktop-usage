// Menu-bar Claude.ai usage app. The status item shows the 5-hour bucket
// (title / reset countdown / progress bar / percent); clicking it opens a
// popover with the weekly + per-model buckets and the action rows.
// Build via ./build_app.sh.

import Cocoa

// MARK: - UI scale

/// Global UI scale factor for the popover contents. Multiply hard-coded font
/// sizes and dimensions by this so the popover grows/shrinks together.
let uiScale: CGFloat = 1.2
@inline(__always) func sc(_ v: CGFloat) -> CGFloat { (v * uiScale).rounded() }

// MARK: - Settings

struct RefreshChoice {
    static let options: [(label: String, seconds: TimeInterval)] = [
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("30 min", 1800),
    ]
}

enum Settings {
    private static let intervalKey = "refreshInterval"

    static var refreshInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: intervalKey)
            return v > 0 ? v : 300
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
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
        return isDark ? NSColor(white: 0.42, alpha: 1.0) : NSColor(white: 0.74, alpha: 1.0)
    })

// MARK: - Data (unchanged fetch pipeline)

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

// MARK: - Status-bar 5-hour view

/// The custom view embedded in the menu-bar status item. Mirrors the layout in
/// the spec: "5-hour" title with a reset countdown beneath it, a progress bar,
/// and the percentage. Sized small to fit the menu-bar height.
final class StatusBarUsageView: NSView {
    private let titleLabel = NSTextField(labelWithString: "5-hour")
    private let subtitleLabel = NSTextField(labelWithString: "—")
    private let bar = ProgressBar()
    private let pctLabel = NSTextField(labelWithString: "—")
    private var resetsAt: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        pctLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        pctLabel.textColor = .secondaryLabelColor
        pctLabel.alignment = .right

        bar.translatesAutoresizingMaskIntoConstraints = false
        pctLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 46),
            bar.heightAnchor.constraint(equalToConstant: 5),
            pctLabel.widthAnchor.constraint(equalToConstant: 28),
        ])

        let vstack = NSStackView(views: [titleLabel, subtitleLabel])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 0

        let main = NSStackView(views: [vstack, bar, pctLabel])
        main.orientation = .horizontal
        main.alignment = .centerY
        main.spacing = 5
        main.translatesAutoresizingMaskIntoConstraints = false
        addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor),
            main.trailingAnchor.constraint(equalTo: trailingAnchor),
            main.topAnchor.constraint(equalTo: topAnchor),
            main.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Let clicks fall through to the status-item button so it can open the popover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ bucket: Usage.Bucket?) {
        guard let b = bucket else { showError(); return }
        resetsAt = b.resetsAt
        let color = tierColor(forUtilization: b.pct)
        bar.fillColor = color
        bar.value = b.pct
        if let v = b.pct {
            pctLabel.stringValue = String(format: "%.0f%%", v)
            pctLabel.textColor = (v < 75) ? .secondaryLabelColor : color
        } else {
            pctLabel.stringValue = "—"
            pctLabel.textColor = .secondaryLabelColor
        }
        refreshCountdown()
    }

    func refreshCountdown() {
        subtitleLabel.stringValue = formatCountdown(resetsAt)
    }

    func showError() {
        bar.value = nil
        pctLabel.stringValue = "—"
        pctLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = "error"
    }
}

// MARK: - Metric block (popover rows)

final class MetricBlock {
    enum Layout { case full, compact }

    let name: String
    let layout: Layout
    let titleLabel = NSTextField(labelWithString: "")
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
            ? .systemFont(ofSize: sc(11), weight: .semibold)
            : .systemFont(ofSize: sc(10), weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: sc(9), weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        pctLabel.font = .monospacedDigitSystemFont(ofSize: sc(9), weight: .regular)
        pctLabel.textColor = .secondaryLabelColor
        pctLabel.alignment = .right

        bar.translatesAutoresizingMaskIntoConstraints = false
        pctLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: sc(56)),
            bar.heightAnchor.constraint(equalToConstant: sc(4)),
            pctLabel.widthAnchor.constraint(equalToConstant: sc(26)),
        ])

        let leftGroup: NSView
        if layout == .full {
            let vstack = NSStackView(views: [titleLabel, subtitleLabel])
            vstack.orientation = .vertical
            vstack.alignment = .leading
            vstack.spacing = sc(1)
            leftGroup = vstack
        } else {
            leftGroup = titleLabel
        }
        leftGroup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leftGroup.widthAnchor.constraint(equalToConstant: sc(60)),
        ])

        view = NSStackView(views: [leftGroup, bar, pctLabel])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = sc(5)
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
        subtitleLabel.stringValue = formatCountdown(lastResetsAt)
    }

    func showError() {
        bar.value = nil
        pctLabel.stringValue = "—"
        pctLabel.textColor = .secondaryLabelColor
        if layout == .full {
            subtitleLabel.stringValue = "error"
        }
    }
}

// MARK: - Menu row

/// A full-width clickable row used for the popover's action items. Unlike
/// NSButton it places its label flush at the row's leading edge (so it lines up
/// exactly with the section headers above) and honors an explicit height.
final class MenuRow: NSView {
    private let onClick: (() -> Void)?
    private let innerPad: CGFloat
    private var trackingArea: NSTrackingArea?
    private var hovering = false { didSet { updateHighlight() } }

    init(width: CGFloat, height: CGFloat, innerPad: CGFloat, onClick: (() -> Void)?) {
        self.onClick = onClick
        self.innerPad = innerPad
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = sc(4)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func addLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: sc(11))
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: innerPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return label
    }

    func addTrailing(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -innerPad),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { if onClick != nil { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func updateHighlight() {
        layer?.backgroundColor =
            hovering ? NSColor.labelColor.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
    }
}

// MARK: - Popover content

final class PopoverView: NSView {
    let sevenDayBlock = MetricBlock(name: "All models", layout: .full)
    let sonnetBlock = MetricBlock(name: "Sonnet", layout: .compact)
    let opusBlock = MetricBlock(name: "Opus", layout: .compact)
    let oauthBlock = MetricBlock(name: "Apps", layout: .compact)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private weak var appDelegate: AppDelegate?
    // Two levels of inset, menu-style:
    //   popover edge -> outerPad -> row highlight -> innerPad -> text.
    // textWidth matches a full metric row (left group + bar + percent), so the
    // bars/percent line up with the action labels and the popup above/below.
    private let outerPad = sc(8)
    private let innerPad = sc(4)
    private let textWidth = sc(60) + sc(56) + sc(26) + sc(5) * 2
    // A row spans the full highlight width: the text column plus inner padding
    // on both sides.
    private var rowWidth: CGFloat { textWidth + innerPad * 2 }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = sc(6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Outer inset: keep the row highlights away from the popover edges.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: outerPad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -outerPad),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: sc(10)),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -sc(8)),
        ])

        let weeklyHeader = paddedRow(sectionHeader("WEEKLY"))
        let modelsHeader = paddedRow(sectionHeader("MODELS"))
        let refreshNow = actionRow("Refresh Now") { [weak self] in self?.appDelegate?.refresh() }
        let openClaude = actionRow("Open Claude.ai") { [weak self] in self?.appDelegate?.openClaude() }
        let intervalRow = makeIntervalRow()
        let quit = actionRow("Quit") { NSApp.terminate(nil) }
        let topSeparator = separator()
        let bottomSeparator = separator()

        let sevenDayRow = paddedRow(sevenDayBlock.view)
        let oauthRow = paddedRow(oauthBlock.view)

        stack.addArrangedSubview(weeklyHeader)
        stack.addArrangedSubview(sevenDayRow)
        stack.addArrangedSubview(modelsHeader)
        stack.addArrangedSubview(paddedRow(sonnetBlock.view))
        stack.addArrangedSubview(paddedRow(opusBlock.view))
        stack.addArrangedSubview(oauthRow)
        stack.addArrangedSubview(topSeparator)
        stack.addArrangedSubview(refreshNow)
        stack.addArrangedSubview(openClaude)
        stack.addArrangedSubview(intervalRow)
        stack.addArrangedSubview(bottomSeparator)
        stack.addArrangedSubview(quit)

        stack.setCustomSpacing(sc(4), after: weeklyHeader)
        stack.setCustomSpacing(sc(9), after: sevenDayRow)
        stack.setCustomSpacing(sc(4), after: modelsHeader)
        stack.setCustomSpacing(sc(6), after: oauthRow)
        stack.setCustomSpacing(sc(4), after: topSeparator)
        stack.setCustomSpacing(sc(1), after: refreshNow)
        stack.setCustomSpacing(sc(1), after: openClaude)
        stack.setCustomSpacing(sc(4), after: intervalRow)
        stack.setCustomSpacing(sc(4), after: bottomSeparator)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: sc(8), weight: .bold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// Wrap non-highlight content (headers, metric rows) in a full row-width
    /// container with the same inner padding as the action rows, so their text
    /// lines up with the action labels.
    private func paddedRow(_ content: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: rowWidth),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: innerPad),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        return box
    }

    private func actionRow(_ title: String, onClick: @escaping () -> Void) -> MenuRow {
        let row = MenuRow(width: rowWidth, height: sc(14), innerPad: innerPad, onClick: onClick)
        row.addLabel(title)
        return row
    }

    private func makeIntervalRow() -> MenuRow {
        let row = MenuRow(width: rowWidth, height: sc(18), innerPad: innerPad, onClick: nil)
        row.addLabel("Refresh Every")

        for opt in RefreshChoice.options {
            intervalPopup.addItem(withTitle: opt.label)
            intervalPopup.lastItem?.representedObject = opt.seconds
        }
        intervalPopup.target = appDelegate
        intervalPopup.action = #selector(AppDelegate.setInterval(_:))
        intervalPopup.font = .systemFont(ofSize: sc(10))
        intervalPopup.controlSize = .small
        syncIntervalSelection()
        row.addTrailing(intervalPopup)
        return row
    }

    func syncIntervalSelection() {
        for item in intervalPopup.itemArray {
            if let s = item.representedObject as? TimeInterval, s == Settings.refreshInterval {
                intervalPopup.select(item)
                return
            }
        }
    }

    func update(_ usage: Usage?) {
        guard let u = usage else {
            [sevenDayBlock, sonnetBlock, opusBlock, oauthBlock].forEach { $0.showError() }
            return
        }
        sevenDayBlock.update(u.sevenDay)
        sonnetBlock.update(u.sevenDaySonnet)
        opusBlock.update(u.sevenDayOpus)
        oauthBlock.update(u.sevenDayOAuth)
    }

    func tickCountdowns() {
        sevenDayBlock.refreshCountdown()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let usageView = StatusBarUsageView()
    private let popover = NSPopover()
    private var popoverView: PopoverView!
    private var fetchTimer: Timer?
    private var countdownTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.addSubview(usageView)
            NSLayoutConstraint.activate([
                usageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
                usageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateStatusLength()

        popoverView = PopoverView(appDelegate: self)
        let vc = NSViewController()
        vc.view = popoverView
        popover.contentViewController = vc
        popover.behavior = .transient

        refresh()
        restartFetchTimer()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            self?.usageView.refreshCountdown()
            self?.popoverView.tickCountdowns()
            self?.updateStatusLength()
        }
    }

    private func updateStatusLength() {
        usageView.layoutSubtreeIfNeeded()
        statusItem.length = usageView.fittingSize.width + 12
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            popoverView.syncIntervalSelection()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
            guard let self = self else { return }
            self.usageView.update(usage?.fiveHour)
            self.popoverView.update(usage)
            self.updateStatusLength()
        }
    }

    @objc func openClaude() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func setInterval(_ sender: NSPopUpButton) {
        guard let interval = sender.selectedItem?.representedObject as? TimeInterval else { return }
        Settings.refreshInterval = interval
        restartFetchTimer()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
