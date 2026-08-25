import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

private let background = NSColor(calibratedRed: 0.082, green: 0.090, blue: 0.110, alpha: 0.88)
private let foreground = NSColor(calibratedWhite: 0.96, alpha: 1)
private let muted = NSColor(calibratedWhite: 0.62, alpha: 1)
private let blue = NSColor(calibratedRed: 0.39, green: 0.66, blue: 1.0, alpha: 1)
private let green = NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.59, alpha: 1)
private let amber = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.36, alpha: 1)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var usageClient = CodexUsageClient()
    private var resetClient = ResetCreditsClient()
    private let sessionMonitor = SessionMonitor()
    private let fullscreenQueue = DispatchQueue(label: "CodexOverlay.fullscreen", qos: .utility)
    private var refreshTimer: Timer?
    private var fullscreenTimer: Timer?
    private var fullscreenCheckInFlight = false
    private var usageSummary = "用量 --"
    private var activity = ActivitySnapshot.idle
    private var isClickThrough = false
    private var manuallyHidden = false
    private var automaticallyHidden = false
    private var autoHideInFullscreen = UserDefaults.standard.object(forKey: "autoHideInFullscreen") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 双击启动时应有明确可见反馈；菜单栏图标仍会同时保留。
        NSApp.setActivationPolicy(.regular)
        panel = OverlayPanel(delegate: self)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex 悬浮窗")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if autoHideInFullscreen { FullscreenDetector.requestAccessibilityIfNeeded() }
        initializeVisibility()
        performRefresh(forceReset: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.performRefresh(forceReset: false)
        }
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateFullscreenVisibility()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) { usageClient.stop() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "显示 Codex 悬浮窗", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        let clickItem = menu.addItem(withTitle: "鼠标穿透", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.state = isClickThrough ? .on : .off
        let fullscreenItem = menu.addItem(withTitle: "全屏时自动隐藏", action: #selector(toggleAutoHideInFullscreen), keyEquivalent: "")
        fullscreenItem.target = self
        fullscreenItem.state = autoHideInFullscreen ? .on : .off
        if autoHideInFullscreen {
            if AXIsProcessTrusted() {
                let permissionItem = menu.addItem(withTitle: "网页全屏检测：已启用", action: nil, keyEquivalent: "")
                permissionItem.isEnabled = false
            } else {
                menu.addItem(withTitle: "网页全屏检测：需要辅助功能权限", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            }
        }
        if #available(macOS 13.0, *) {
            let launchItem = menu.addItem(withTitle: "登录时打开", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex 悬浮窗", action: #selector(quit), keyEquivalent: "q")
    }

    @objc func showPanel() {
        manuallyHidden = false
        automaticallyHidden = false
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc func refresh() {
        performRefresh(forceReset: true)
    }

    private func performRefresh(forceReset: Bool) {
        panel.restoreSavedSizeIfNeeded()
        panel.setConnection("正在读取 Codex 用量…")
        sessionMonitor.scan { [weak self] snapshot in
            guard let self else { return }
            self.activity = snapshot
            self.panel.setActivity(snapshot)
            self.updateMenuTitle()
        }
        usageClient.refresh { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.usageSummary = snapshot.menuText
                    self.panel.setUsage(snapshot)
                    self.panel.setConnection("已连接 Codex")
                case .failure(let error):
                    self.panel.setConnection(error.localizedDescription)
                }
                self.updateMenuTitle()
            }
        }
        resetClient.refresh(force: forceReset) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot): self.panel.setReset(snapshot)
                case .failure: self.panel.setReset(nil)
                }
            }
        }
    }

    @objc func toggleClickThrough() {
        isClickThrough.toggle()
        panel.ignoresMouseEvents = isClickThrough
    }

    @objc private func toggleAutoHideInFullscreen() {
        autoHideInFullscreen.toggle()
        UserDefaults.standard.set(autoHideInFullscreen, forKey: "autoHideInFullscreen")
        if autoHideInFullscreen {
            FullscreenDetector.requestAccessibilityIfNeeded()
            updateFullscreenVisibility()
        } else if automaticallyHidden {
            automaticallyHidden = false
            if !manuallyHidden { panel.orderFrontRegardless() }
        }
    }

    @objc private func openAccessibilitySettings() {
        FullscreenDetector.requestAccessibilityIfNeeded()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @available(macOS 13.0, *) @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError("无法更新登录启动：\(error.localizedDescription)") }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func hidePanel() {
        manuallyHidden = true
        automaticallyHidden = false
        panel.orderOut(nil)
    }

    private func updateFullscreenVisibility() {
        guard autoHideInFullscreen else { return }
        guard !fullscreenCheckInFlight else { return }
        guard let context = FullscreenDetector.captureFrontmostApp(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        ) else {
            applyFullscreenVisibility(.none)
            return
        }
        fullscreenCheckInFlight = true
        fullscreenQueue.async { [weak self] in
            let state = FullscreenDetector.inspect(context)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fullscreenCheckInFlight = false
                guard self.autoHideInFullscreen else { return }
                self.applyFullscreenVisibility(state)
            }
        }
    }

    private func applyFullscreenVisibility(_ state: FullscreenDetector.State) {
        let fullscreen = state.coversDisplay || state.likelyWebVideoFullscreen
        if fullscreen {
            automaticallyHidden = true
            if panel.isVisible {
                panel.orderOut(nil)
            }
        } else if automaticallyHidden {
            automaticallyHidden = false
            if !manuallyHidden { panel.orderFrontRegardless() }
        }
    }

    private func initializeVisibility() {
        // 常规 Dock 应用启动时会被系统自动激活；先退回后台，再检查原本的前台窗口。
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.updateFullscreenVisibility()
            if !self.automaticallyHidden && !self.manuallyHidden {
                self.panel.orderFrontRegardless()
            }
        }
    }

    @objc private func handleSystemWake() {
        // 屏幕恢复后 AppKit 还会继续重排一小段时间，延后校正可避免再次被覆盖。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.panel.restoreSavedSizeIfNeeded(force: true)
        }
    }

    @objc private func handleScreenChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.panel.restoreSavedSizeIfNeeded(force: true)
        }
    }

    private func updateMenuTitle() {
        statusItem.button?.toolTip = "Codex \(activity.title) · \(usageSummary)"
    }

    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Codex 悬浮窗"; alert.informativeText = text; alert.runModal()
    }
}

private enum FullscreenDetector {
    struct ScreenRegion {
        let display: CGRect
        let visible: CGRect
    }

    struct Context {
        let pid: pid_t
        let bundleIdentifier: String?
        let screenRegions: [ScreenRegion]
    }

    struct State {
        let pid: pid_t?
        let coversDisplay: Bool
        let coversVisibleArea: Bool
        let likelyWebVideoFullscreen: Bool
        static let none = State(pid: nil, coversDisplay: false, coversVisibleArea: false, likelyWebVideoFullscreen: false)
    }

    // AppKit 的前台应用和屏幕坐标需从主线程读取；之后的窗口列举和辅助功能查询
    // 会由专用后台队列处理，避免拖动、悬停等界面事件被阻塞。
    static func captureFrontmostApp(excludingPID: pid_t) -> Context? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = application.processIdentifier
        guard pid != excludingPID else { return nil }

        let screenRegions = NSScreen.screens.compactMap { screen -> ScreenRegion? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let visible = screen.visibleFrame
            let screenFrame = screen.frame
            let visibleInQuartz = CGRect(
                x: display.minX + visible.minX - screenFrame.minX,
                y: display.minY + screenFrame.maxY - visible.maxY,
                width: visible.width,
                height: visible.height
            )
            return ScreenRegion(display: display, visible: visibleInQuartz)
        }
        return Context(pid: pid, bundleIdentifier: application.bundleIdentifier, screenRegions: screenRegions)
    }

    static func inspect(_ context: Context) -> State {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return State(pid: context.pid, coversDisplay: false, coversVisibleArea: false, likelyWebVideoFullscreen: false)
        }

        var coversDisplay = false
        var visibleAreaWindows: [CGRect] = []
        for window in rawWindows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == context.pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { continue }

            for region in context.screenRegions {
                if coversRegion(window: bounds, region: region.display, tolerance: 0.985) {
                    coversDisplay = true
                }
                if matchesVisibleArea(window: bounds, visible: region.visible) {
                    visibleAreaWindows.append(bounds)
                }
            }
        }
        let mediaBundles: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
            "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
            "com.operasoftware.Opera", "com.apple.QuickTimePlayerX",
            "org.videolan.vlc", "com.colliderli.iina"
        ]
        let isMediaApplication = mediaBundles.contains(context.bundleIdentifier ?? "")
        let coversVisibleArea = !visibleAreaWindows.isEmpty
        let toolbarVisibility = isMediaApplication
            ? browserToolbarIsVisible(pid: context.pid, matching: visibleAreaWindows)
            : nil
        // 网页全屏与普通最大化可能拥有完全相同的窗口尺寸；未获辅助功能权限时不做猜测。
        let likelyWebVideoFullscreen = coversVisibleArea && isMediaApplication && toolbarVisibility == false
        return State(
            pid: context.pid,
            coversDisplay: coversDisplay,
            coversVisibleArea: coversVisibleArea,
            likelyWebVideoFullscreen: likelyWebVideoFullscreen
        )
    }

    private static func coversRegion(window: CGRect, region: CGRect, tolerance: CGFloat) -> Bool {
        let intersection = window.intersection(region)
        guard !intersection.isNull, region.width > 0, region.height > 0 else { return false }
        return intersection.width / region.width >= tolerance && intersection.height / region.height >= tolerance
    }

    private static func matchesVisibleArea(window: CGRect, visible: CGRect) -> Bool {
        guard coversRegion(window: window, region: visible, tolerance: 0.98) else { return false }
        return abs(window.minX - visible.minX) <= 10 &&
            abs(window.maxX - visible.maxX) <= 10 &&
            abs(window.minY - visible.minY) <= 10 &&
            abs(window.maxY - visible.maxY) <= 12
    }

    static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private static func browserToolbarIsVisible(pid: pid_t, matching candidates: [CGRect]) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)

        // Chrome 可能同时有多个窗口；必须检查与 CGWindow 全屏候选尺寸相符的窗口，
        // 不能只读 focusedWindow（切换 Space 或播放器全屏时它可能仍指向另一个普通窗口）。
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] {
            let matchingWindows = windows.filter { window in
                guard let bounds = accessibilityBounds(of: window) else { return false }
                return candidates.contains { approximatelyEqual(bounds, $0) }
            }
            if !matchingWindows.isEmpty {
                for window in matchingWindows {
                    var inspected = 0
                    if containsVisibleToolbar(window, depth: 0, inspected: &inspected) { return true }
                }
                return false
            }
        }

        // 某些播放器不会把全屏窗口列入 AXWindows，保留 focusedWindow 作为兼容回退。
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success, let focusedValue else { return nil }
        let window = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var inspected = 0
        return containsVisibleToolbar(window, depth: 0, inspected: &inspected)
    }

    private static func accessibilityBounds(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let dimensions = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 12 &&
            abs(lhs.minY - rhs.minY) <= 12 &&
            abs(lhs.width - rhs.width) <= 16 &&
            abs(lhs.height - rhs.height) <= 16
    }

    private static func containsVisibleToolbar(
        _ element: AXUIElement,
        depth: Int,
        inspected: inout Int
    ) -> Bool {
        guard depth <= 5, inspected < 160 else { return false }
        inspected += 1

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           role == (kAXToolbarRole as String) {
            var hiddenValue: CFTypeRef?
            let hiddenResult = AXUIElementCopyAttributeValue(
                element,
                kAXHiddenAttribute as CFString,
                &hiddenValue
            )
            return hiddenResult != .success || (hiddenValue as? Bool) != true
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else { return false }

        for child in children {
            if containsVisibleToolbar(child, depth: depth + 1, inspected: &inspected) { return true }
        }
        return false
    }
}

private final class OverlayPanel: NSPanel, NSWindowDelegate {
    static let defaultSize = NSSize(width: 176, height: 104)
    static let minimumSize = NSSize(width: 154, height: 96)
    static let maximumSize = NSSize(width: 420, height: 260)
    // V4 曾在系统自动拉伸窗口后被普通拖动写入异常尺寸；V6 为双用量行预留足够高度。
    private static let sizePreferenceKey = "panelSizeV6"
    private static let legacySizePreferenceKeys = ["panelSizeV5", "panelSizeV4"]

    private let statusLabel = NSTextField(labelWithString: "正在检查任务状态")
    private let dot = NSTextField(labelWithString: "●")
    private let shortPeriodLabel = NSTextField(labelWithString: "5小时用量")
    private let shortNextRefreshLabel = NSTextField(labelWithString: "刷新 --")
    private let shortPercentageLabel = NSTextField(labelWithString: "--")
    private let weeklyPeriodLabel = NSTextField(labelWithString: "周用量")
    private let weeklyNextRefreshLabel = NSTextField(labelWithString: "刷新 --")
    private let weeklyPercentageLabel = NSTextField(labelWithString: "--")
    private let resetCountLabel = NSTextField(labelWithString: "重置 --")
    private let resetExpiryLabel = NSTextField(labelWithString: "--")
    private let connectionLabel = NSTextField(labelWithString: "正在连接 Codex")
    private let shortProgress = NSProgressIndicator()
    private let weeklyProgress = NSProgressIndicator()
    private weak var appDelegate: AppDelegate?
    private var baseFonts: [ObjectIdentifier: (label: NSTextField, size: CGFloat, weight: NSFont.Weight)] = [:]
    private var isUserResizing = false
    private var isCorrectingSize = false

    init(delegate: AppDelegate) {
        self.appDelegate = delegate
        // 仅使用自定义右下角缩放柄。borderless + 系统 resizable 在屏幕唤醒时可能被 AppKit 横向拉伸。
        super.init(contentRect: Self.initialFrame(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        minSize = Self.minimumSize
        maxSize = Self.maximumSize
        self.delegate = self
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        setupContent()
        updateTypography()
    }

    private static func initialFrame() -> NSRect {
        let defaults = UserDefaults.standard
        let size = savedSize(defaults: defaults) ?? defaultSize
        if let value = defaults.string(forKey: "panelOrigin") {
            let point = NSPointFromString(value)
            let savedFrame = NSRect(origin: point, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                return constrainedToVisibleScreen(savedFrame)
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSRect(x: screen.maxX - size.width - 28, y: screen.maxY - size.height - 48, width: size.width, height: size.height)
    }

    private static func isValidSize(_ size: NSSize) -> Bool {
        size.width >= minimumSize.width && size.height >= minimumSize.height &&
            size.width <= maximumSize.width && size.height <= maximumSize.height
    }

    private static func savedSize(defaults: UserDefaults) -> NSSize? {
        if let value = defaults.string(forKey: sizePreferenceKey) {
            let size = NSSizeFromString(value)
            if isValidSize(size) { return size }
        }

        // 保留此前用户正常调整过的尺寸，但丢弃类似 541 × 82 的异常 V4 记录。
        for key in legacySizePreferenceKeys {
            if let value = defaults.string(forKey: key) {
                let size = NSSizeFromString(value)
                if isValidSize(size) {
                    defaults.set(NSStringFromSize(size), forKey: sizePreferenceKey)
                    return size
                }
            }
        }
        return nil
    }

    private static func constrainedToVisibleScreen(_ candidate: NSRect) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(candidate) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return candidate }
        var result = candidate
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    private func setupContent() {
        // 直接用不透明深色背景，避免 macOS 15 上 NSVisualEffectView 的 .hudWindow 材质失效导致白底白字。
        let container = NSView(frame: contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 0
        container.layer?.backgroundColor = background.cgColor
        contentView = container

        let body = NSStackView()
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 3
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -2)
        ])

        let statusRow = NSStackView(views: [dot, statusLabel])
        statusRow.spacing = 5
        style(dot, color: amber, size: 10, bold: true)
        style(statusLabel, color: foreground, size: 13, bold: true)
        body.addArrangedSubview(statusRow)

        let shortUsageRow = makeUsageRow(
            period: shortPeriodLabel,
            refresh: shortNextRefreshLabel,
            percentage: shortPercentageLabel
        )
        body.addArrangedSubview(shortUsageRow)
        shortUsageRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureProgress(shortProgress)
        body.addArrangedSubview(shortProgress)
        shortProgress.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let weeklyUsageRow = makeUsageRow(
            period: weeklyPeriodLabel,
            refresh: weeklyNextRefreshLabel,
            percentage: weeklyPercentageLabel
        )
        body.addArrangedSubview(weeklyUsageRow)
        weeklyUsageRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        configureProgress(weeklyProgress)
        body.addArrangedSubview(weeklyProgress)
        weeklyProgress.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let resetRow = NSStackView()
        resetRow.orientation = .horizontal; resetRow.distribution = .fillEqually
        style(resetCountLabel, color: muted, size: 11, bold: false)
        style(resetExpiryLabel, color: muted, size: 10, bold: false); resetExpiryLabel.alignment = .right
        resetRow.addArrangedSubview(resetCountLabel); resetRow.addArrangedSubview(resetExpiryLabel)
        body.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        style(connectionLabel, color: muted, size: 10, bold: false)
        connectionLabel.lineBreakMode = .byTruncatingTail
        connectionLabel.maximumNumberOfLines = 1
        connectionLabel.cell?.usesSingleLineMode = true
        connectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        connectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.addArrangedSubview(connectionLabel)
        connectionLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let resizeHandle = ResizeHandleView(panel: self)
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 15),
            resizeHandle.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    override func mouseDown(with event: NSEvent) { performDrag(with: event); savePosition() }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "立即刷新", action: #selector(AppDelegate.refresh), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏到菜单栏", action: #selector(AppDelegate.hidePanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(AppDelegate.quit), keyEquivalent: "")
        menu.items.forEach { $0.target = appDelegate }
        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? NSView())
    }
    func windowDidResize(_ notification: Notification) {
        updateTypography()
        // 只有右下角缩放柄产生的尺寸变化才算用户操作。系统在切换 Space、
        // 全屏或唤醒屏幕时偶尔会拉伸 borderless panel，下一轮主线程立即纠正。
        if !isUserResizing && !isCorrectingSize {
            DispatchQueue.main.async { [weak self] in
                self?.restoreSavedSizeIfNeeded()
            }
        }
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panelOrigin")
    }

    fileprivate func beginUserResize() { isUserResizing = true }
    fileprivate func endUserResize() {
        isUserResizing = false
        let size = frame.size
        guard Self.isValidSize(size) else {
            restore(size: Self.defaultSize)
            return
        }
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizePreferenceKey)
        savePosition()
    }

    fileprivate func restoreSavedSizeIfNeeded(force: Bool = false) {
        guard !isUserResizing, !isCorrectingSize else { return }
        let saved = Self.savedSize(defaults: .standard) ?? Self.defaultSize
        let differs = abs(frame.width - saved.width) > 1 || abs(frame.height - saved.height) > 1
        guard force || differs else { return }

        restore(size: saved)
    }

    private func restore(size saved: NSSize) {
        isCorrectingSize = true
        var corrected = frame
        let top = corrected.maxY
        corrected.size = saved
        corrected.origin.y = top - saved.height
        corrected = Self.constrainedToVisibleScreen(corrected)
        setFrame(corrected, display: true)
        isCorrectingSize = false
        updateTypography()
    }

    func setActivity(_ snapshot: ActivitySnapshot) {
        statusLabel.stringValue = snapshot.title
        dot.textColor = snapshot.status == .running ? green : (snapshot.status == .idle ? blue : amber)
    }
    func setUsage(_ snapshot: UsageSnapshot) {
        setUsageWindow(
            snapshot.shortWindow,
            periodLabel: shortPeriodLabel,
            refreshLabel: shortNextRefreshLabel,
            percentageLabel: shortPercentageLabel,
            progress: shortProgress
        )
        setUsageWindow(
            snapshot.weeklyWindow,
            periodLabel: weeklyPeriodLabel,
            refreshLabel: weeklyNextRefreshLabel,
            percentageLabel: weeklyPercentageLabel,
            progress: weeklyProgress
        )
    }
    func setReset(_ snapshot: ResetCreditsSnapshot?) {
        guard let snapshot else {
            resetCountLabel.stringValue = "重置 --"
            resetExpiryLabel.stringValue = "--"
            return
        }
        resetCountLabel.stringValue = "重置 \(snapshot.availableCount)次"
        resetExpiryLabel.stringValue = snapshot.nearestExpiryText
    }
    func setConnection(_ text: String) {
        connectionLabel.stringValue = text.count > 36 ? "Codex 用量读取失败" : text
        connectionLabel.toolTip = text
        // 长错误消息可能在本轮 Auto Layout 中短暂改变 panel 的 fitting size；
        // 文案更新完成后再次锁回用户保存的有效尺寸。
        DispatchQueue.main.async { [weak self] in
            self?.restoreSavedSizeIfNeeded(force: true)
        }
    }

    private func makeUsageRow(period: NSTextField, refresh: NSTextField, percentage: NSTextField) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal; row.distribution = .fill; row.spacing = 4
        style(period, color: muted, size: 11, bold: false)
        style(refresh, color: muted, size: 10, bold: false)
        style(percentage, color: foreground, size: 11, bold: true); percentage.alignment = .right
        period.setContentHuggingPriority(.required, for: .horizontal)
        period.setContentCompressionResistancePriority(.required, for: .horizontal)
        refresh.alignment = .right
        refresh.lineBreakMode = .byTruncatingTail
        refresh.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refresh.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        percentage.setContentHuggingPriority(.required, for: .horizontal)
        percentage.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(period)
        row.addArrangedSubview(refresh)
        row.addArrangedSubview(percentage)
        return row
    }

    private func configureProgress(_ progress: NSProgressIndicator) {
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100; progress.doubleValue = 0
        progress.style = .bar; progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 2).isActive = true
    }

    private func setUsageWindow(
        _ window: UsageWindowSnapshot,
        periodLabel: NSTextField,
        refreshLabel: NSTextField,
        percentageLabel: NSTextField,
        progress: NSProgressIndicator
    ) {
        periodLabel.stringValue = window.period
        refreshLabel.stringValue = window.nextRefreshText
        refreshLabel.toolTip = window.nextRefreshTooltip
        percentageLabel.stringValue = window.percentageText
        progress.doubleValue = window.usedPercent ?? 0
    }
    private func style(_ label: NSTextField, color: NSColor, size: CGFloat, bold: Bool) {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        label.textColor = color
        label.font = .systemFont(ofSize: size, weight: weight)
        baseFonts[ObjectIdentifier(label)] = (label, size, weight)
    }

    fileprivate func updateTypography() {
        let widthRatio = frame.width / Self.defaultSize.width
        let heightRatio = frame.height / Self.defaultSize.height
        let scale = min(1.8, max(0.82, min(widthRatio, heightRatio)))
        for entry in baseFonts.values {
            entry.label.font = .systemFont(ofSize: entry.size * scale, weight: entry.weight)
        }
    }
}

private final class ResizeHandleView: NSView {
    private weak var panel: OverlayPanel?
    private var startFrame = NSRect.zero
    private var startPoint = NSPoint.zero

    init(panel: OverlayPanel) {
        self.panel = panel
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.20).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        path.move(to: NSPoint(x: bounds.maxX - 4, y: 2)); path.line(to: NSPoint(x: bounds.maxX - 2, y: 4))
        path.move(to: NSPoint(x: bounds.maxX - 8, y: 2)); path.line(to: NSPoint(x: bounds.maxX - 2, y: 8))
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        panel.beginUserResize()
        startFrame = panel.frame
        startPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        let width = min(OverlayPanel.maximumSize.width, max(OverlayPanel.minimumSize.width, startFrame.width + dx))
        let height = min(OverlayPanel.maximumSize.height, max(OverlayPanel.minimumSize.height, startFrame.height - dy))
        let bottom = startFrame.maxY - height
        panel.setFrame(NSRect(x: startFrame.minX, y: bottom, width: width, height: height), display: true)
        panel.updateTypography()
    }

    override func mouseUp(with event: NSEvent) { panel?.endUserResize() }
}

private struct UsageWindowSnapshot {
    let usedPercent: Double?
    let period: String
    let resetsAt: Date?
    let windowDurationMins: Int?

    static func unavailable(period: String, windowDurationMins: Int?) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            usedPercent: nil,
            period: period,
            resetsAt: nil,
            windowDurationMins: windowDurationMins
        )
    }

    var percentageText: String {
        guard let usedPercent else { return "--" }
        return "\(Int(usedPercent.rounded()))%"
    }

    var nextRefreshText: String {
        guard let resetsAt else { return "刷新 --" }
        let formatter = (windowDurationMins ?? 0) <= 24 * 60
            ? Self.hourFormatter
            : Self.shortDateFormatter
        return "刷新 \(formatter.string(from: resetsAt))"
    }

    var nextRefreshTooltip: String {
        guard let resetsAt else { return "Codex 未返回下次用量刷新时间" }
        return "下次用量刷新：\(Self.fullDateFormatter.string(from: resetsAt)) +8"
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter
    }()
}

private struct UsageSnapshot {
    let shortWindow: UsageWindowSnapshot
    let weeklyWindow: UsageWindowSnapshot

    var menuText: String {
        "\(shortWindow.period) \(shortWindow.percentageText) · \(weeklyWindow.period) \(weeklyWindow.percentageText)"
    }
}

private struct ResetCreditsSnapshot {
    let availableCount: Int
    let expiries: [Date]

    var nearestExpiryText: String {
        guard availableCount > 0, let date = expiries.min() else { return "--" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M/d HH:mm '+8'"
        return formatter.string(from: date)
    }
}

private final class ResetCreditsClient {
    private let queue = DispatchQueue(label: "CodexOverlay.resetCredits")
    private var cached: ResetCreditsSnapshot?
    private var lastAttempt: Date?

    func refresh(force: Bool, completion: @escaping (Result<ResetCreditsSnapshot, Error>) -> Void) {
        queue.async {
            if !force, let lastAttempt = self.lastAttempt,
               Date().timeIntervalSince(lastAttempt) < 3600 {
                if let cached = self.cached { completion(.success(cached)) }
                else { completion(.failure(OverlayError.invalidResetResponse)) }
                return
            }
            do {
                self.lastAttempt = Date()
                let request = try self.makeRequest()
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error { completion(.failure(error)); return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        completion(.failure(OverlayError.server("重置次数服务返回 \(http.statusCode)"))); return
                    }
                    guard let data else { completion(.failure(OverlayError.invalidResetResponse)); return }
                    do {
                        let snapshot = try Self.parse(data)
                        self.queue.async {
                            self.cached = snapshot
                            completion(.success(snapshot))
                        }
                    } catch { completion(.failure(error)) }
                }.resume()
            } catch { completion(.failure(error)) }
        }
    }

    private func makeRequest() throws -> URLRequest {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let authURL = root.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw OverlayError.noCredentials
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        return request
    }

    private static func parse(_ data: Data) throws -> ResetCreditsSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["available_count"] as? NSNumber,
              let credits = object["credits"] as? [[String: Any]] else {
            throw OverlayError.invalidResetResponse
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
        let dates = credits.compactMap { credit -> Date? in
            guard let value = credit["expires_at"] as? String else { return nil }
            return fractional.date(from: value) ?? standard.date(from: value)
        }
        guard dates.count == credits.count else { throw OverlayError.invalidResetResponse }
        return ResetCreditsSnapshot(availableCount: max(0, number.intValue), expiries: dates)
    }
}

private final class CodexUsageClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "CodexOverlay.appServer")

    func refresh(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        queue.async {
            self.ensureServer { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success: self.request("account/rateLimits/read", params: [:]) { response in
                    completion(response.flatMap { result in
                        guard let snapshot = Self.parseUsage(result) else {
                            return .failure(OverlayError.invalidResponse)
                        }
                        return .success(snapshot)
                    })
                }
                }
            }
        }
    }

    func stop() { queue.async { self.process?.terminate(); self.process = nil } }

    private func ensureServer(completion: @escaping (Result<Void, Error>) -> Void) {
        if process?.isRunning == true { completion(.success(())); return }
        guard let executable = findCodex() else { completion(.failure(OverlayError.noCodex)); return }
        let task = Process(); task.executableURL = executable; task.arguments = ["app-server", "--listen", "stdio://"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        do { try task.run() } catch { completion(.failure(error)); return }
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData) }
        request("initialize", params: ["clientInfo": ["name": "codex-usage-overlay-mac", "title": "Codex 悬浮窗", "version": "1.0.0"]]) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                self.notify("initialized", params: [:])
                completion(.success(()))
            }
        }
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextId; nextId += 1; pending[id] = completion
        send(["id": id, "method": method, "params": params])
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let callback = self?.pending.removeValue(forKey: id) else { return }
            callback(.failure(OverlayError.timeout))
        }
    }
    private func notify(_ method: String, params: [String: Any]) { send(["method": method, "params": params]) }
    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        input.write(data); input.write(Data([10]))
    }
    private func read(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline); self.buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int,
                      let callback = self.pending.removeValue(forKey: id) else { continue }
                if let error = object["error"] as? [String: Any] { callback(.failure(OverlayError.server(error["message"] as? String ?? "Codex 服务返回错误"))) }
                else { callback(.success(object["result"] as? [String: Any] ?? [:])) }
            }
        }
    }
    private static func parseUsage(_ result: [String: Any]) -> UsageSnapshot? {
        let limits = result["rateLimits"] as? [String: Any] ?? result
        var windows = ["primary", "secondary"].compactMap { key in
            parseUsageWindow(limits[key] as? [String: Any])
        }
        if windows.isEmpty, let legacy = parseUsageWindow(limits["limit"] as? [String: Any]) {
            windows = [legacy]
        }
        guard !windows.isEmpty else { return nil }

        windows.sort { left, right in
            (left.windowDurationMins ?? Int.max) < (right.windowDurationMins ?? Int.max)
        }

        if windows.count == 1, let only = windows.first {
            if (only.windowDurationMins ?? 0) >= 7 * 24 * 60 {
                return UsageSnapshot(
                    shortWindow: .unavailable(period: "5小时用量", windowDurationMins: 5 * 60),
                    weeklyWindow: only
                )
            }
            return UsageSnapshot(
                shortWindow: only,
                weeklyWindow: .unavailable(period: "周用量", windowDurationMins: 7 * 24 * 60)
            )
        }

        return UsageSnapshot(shortWindow: windows[0], weeklyWindow: windows[windows.count - 1])
    }

    private static func parseUsageWindow(_ limit: [String: Any]?) -> UsageWindowSnapshot? {
        guard let limit else { return nil }
        let used = (limit["usedPercent"] as? NSNumber)?.doubleValue ?? (limit["used_percent"] as? NSNumber)?.doubleValue
        guard let used else { return nil }
        let minutes = (limit["windowDurationMins"] as? NSNumber)?.intValue
            ?? (limit["window_duration_mins"] as? NSNumber)?.intValue
        let period: String
        if minutes == 300 { period = "5小时用量" }
        else if minutes == nil { period = "用量" }
        else if minutes == 10080 { period = "周用量" }
        else if let minutes, minutes % 1440 == 0 { period = "\(minutes / 1440)天用量" }
        else if let minutes, minutes % 60 == 0 { period = "\(minutes / 60)小时用量" }
        else { period = "\(minutes!)分钟用量" }
        let resetValue = limit["resetsAt"] ?? limit["resets_at"]
        return UsageWindowSnapshot(
            usedPercent: min(100, max(0, used)),
            period: period,
            resetsAt: Self.parseResetDate(resetValue),
            windowDurationMins: minutes
        )
    }

    private static func parseResetDate(_ value: Any?) -> Date? {
        let raw: Double?
        if let number = value as? NSNumber { raw = number.doubleValue }
        else if let text = value as? String { raw = Double(text) }
        else { raw = nil }
        guard let raw, raw.isFinite, raw > 0 else { return nil }

        // Codex 通常返回 Unix 秒；仍兼容少数客户端/网关传回的毫秒级时间戳。
        let seconds = raw >= 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
    private func findCodex() -> URL? {
        let manager = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_EXE"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ].compactMap { $0 }
        return candidates.first(where: { manager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

private enum OverlayError: LocalizedError {
    case noCodex, noCredentials, timeout, invalidResponse, invalidResetResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .noCodex: return "未找到 Codex，请先安装或设置 CODEX_EXE"
        case .noCredentials: return "未找到 Codex 登录信息"
        case .timeout: return "Codex 服务响应超时"
        case .invalidResponse: return "未能读取当前用量"
        case .invalidResetResponse: return "未能读取重置次数"
        case .server(let message): return message
        }
    }
}

private struct ActivitySnapshot {
    enum Status { case running, idle, unknown }
    let status: Status
    let title: String
    static let idle = ActivitySnapshot(status: .unknown, title: "正在检查任务状态")
}

private final class SessionMonitor {
    private static let maximumSessions = 60
    // 只需找出最后一条任务生命周期事件；读取文件尾部足以避免每分钟重读数百 MB 的历史会话。
    // 某些任务事件会落在超长 JSONL 记录中；1 MB 可覆盖该情况，且每轮最多读取 60 MB。
    private static let tailByteLimit = 1024 * 1024

    private let queue = DispatchQueue(label: "CodexOverlay.sessionMonitor", qos: .utility)
    private var isScanning = false

    func scan(completion: @escaping (ActivitySnapshot) -> Void) {
        // 所有调用来自 AppKit 主线程。进行中的扫描不再排队，保留最近一次已知状态即可。
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            let snapshot = Self.scanSessions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                completion(snapshot)
            }
        }
    }

    private static func scanSessions() -> ActivitySnapshot {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = root.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ActivitySnapshot(status: .unknown, title: "未找到 Codex 会话")
        }

        var sessionFiles: [(url: URL, modified: Date)] = []
        while let path = enumerator.nextObject() as? URL {
            guard path.pathExtension == "jsonl" else { continue }
            let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            sessionFiles.append((url: path, modified: modified))
        }

        let latest = sessionFiles.sorted { $0.modified > $1.modified }.prefix(maximumSessions)
        var active = 0
        var stale = 0
        let now = Date()
        for session in latest {
            guard lastLifecycleEvent(in: session.url) == "task_started" else { continue }
            if now.timeIntervalSince(session.modified) <= 12 * 3600 { active += 1 }
            else { stale += 1 }
        }

        if active > 0 {
            return ActivitySnapshot(status: .running, title: active == 1 ? "执行中" : "执行中 × \(active)")
        }
        if stale > 0 { return ActivitySnapshot(status: .unknown, title: "状态未知") }
        return ActivitySnapshot(status: .idle, title: "空闲")
    }

    private static func lastLifecycleEvent(in path: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let offset = fileSize > UInt64(tailByteLimit) ? fileSize - UInt64(tailByteLimit) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // 倒序读取，找到最新事件就结束，避免对尾部所有 JSON 再做无意义解析。
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  ["task_started", "task_complete", "turn_aborted"].contains(type) else { continue }
            return type
        }
        return nil
    }
}

@main
enum CodexOverlayMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
