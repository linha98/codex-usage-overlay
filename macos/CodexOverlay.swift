import AppKit
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
    private var refreshTimer: Timer?
    private var usage = 0.0
    private var activity = ActivitySnapshot.idle
    private var isClickThrough = false

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
        showPanel()
        performRefresh(forceReset: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.performRefresh(forceReset: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { usageClient.stop() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "显示 Codex 悬浮窗", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        let clickItem = menu.addItem(withTitle: "鼠标穿透", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.state = isClickThrough ? .on : .off
        if #available(macOS 13.0, *) {
            let launchItem = menu.addItem(withTitle: "登录时打开", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex 悬浮窗", action: #selector(quit), keyEquivalent: "q")
    }

    @objc func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc func refresh() {
        performRefresh(forceReset: true)
    }

    private func performRefresh(forceReset: Bool) {
        panel.setConnection("正在读取 Codex 用量…")
        usageClient.refresh { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.usage = snapshot.usedPercent
                    self.panel.setUsage(snapshot)
                    self.panel.setConnection("已连接 Codex")
                case .failure(let error):
                    self.panel.setConnection(error.localizedDescription)
                }
                self.activity = SessionMonitor().scan()
                self.panel.setActivity(self.activity)
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

    @available(macOS 13.0, *) @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError("无法更新登录启动：\(error.localizedDescription)") }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func hidePanel() { panel.orderOut(nil) }

    private func updateMenuTitle() {
        statusItem.button?.toolTip = "Codex \(activity.title) · 用量 \(Int(usage.rounded()))%"
    }

    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Codex 悬浮窗"; alert.informativeText = text; alert.runModal()
    }
}

private final class OverlayPanel: NSPanel {
    static let defaultSize = NSSize(width: 160, height: 78)
    static let minimumSize = NSSize(width: 146, height: 70)
    static let maximumSize = NSSize(width: 420, height: 260)

    private let statusLabel = NSTextField(labelWithString: "正在检查任务状态")
    private let dot = NSTextField(labelWithString: "●")
    private let periodLabel = NSTextField(labelWithString: "周用量")
    private let percentageLabel = NSTextField(labelWithString: "--")
    private let resetCountLabel = NSTextField(labelWithString: "重置 --")
    private let resetExpiryLabel = NSTextField(labelWithString: "--")
    private let connectionLabel = NSTextField(labelWithString: "正在连接 Codex")
    private let progress = NSProgressIndicator()
    private weak var appDelegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.appDelegate = delegate
        super.init(contentRect: Self.initialFrame(), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        minSize = Self.minimumSize
        maxSize = Self.maximumSize
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        setupContent()
    }

    private static func initialFrame() -> NSRect {
        let defaults = UserDefaults.standard
        var size = defaultSize
        if let value = defaults.string(forKey: "panelSizeV2") {
            let saved = NSSizeFromString(value)
            if saved.width >= minimumSize.width, saved.height >= minimumSize.height,
               saved.width <= maximumSize.width, saved.height <= maximumSize.height {
                size = saved
            }
        }
        if let value = defaults.string(forKey: "panelOrigin") {
            let point = NSPointFromString(value)
            let savedFrame = NSRect(origin: point, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                return savedFrame
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSRect(x: screen.maxX - size.width - 28, y: screen.maxY - size.height - 48, width: size.width, height: size.height)
    }

    private func setupContent() {
        // 直接用不透明深色背景，避免 macOS 15 上 NSVisualEffectView 的 .hudWindow 材质失效导致白底白字。
        let container = NSView(frame: contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
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
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5)
        ])

        let statusRow = NSStackView(views: [dot, statusLabel])
        statusRow.spacing = 5
        style(dot, color: amber, size: 8, bold: true)
        style(statusLabel, color: foreground, size: 10, bold: true)
        body.addArrangedSubview(statusRow)

        let usageRow = NSStackView()
        usageRow.orientation = .horizontal; usageRow.distribution = .fillEqually
        style(periodLabel, color: muted, size: 9, bold: false)
        style(percentageLabel, color: foreground, size: 9, bold: true); percentageLabel.alignment = .right
        usageRow.addArrangedSubview(periodLabel); usageRow.addArrangedSubview(percentageLabel)
        body.addArrangedSubview(usageRow)
        usageRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100; progress.doubleValue = 0
        progress.style = .bar; progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 2).isActive = true
        body.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let resetRow = NSStackView()
        resetRow.orientation = .horizontal; resetRow.distribution = .fillEqually
        style(resetCountLabel, color: muted, size: 9, bold: false)
        style(resetExpiryLabel, color: muted, size: 8, bold: false); resetExpiryLabel.alignment = .right
        resetRow.addArrangedSubview(resetCountLabel); resetRow.addArrangedSubview(resetExpiryLabel)
        body.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        style(connectionLabel, color: muted, size: 8, bold: false)
        connectionLabel.lineBreakMode = .byTruncatingTail
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
    override func resignKey() { saveFrame() }

    private func savePosition() { saveFrame() }
    fileprivate func saveFrame() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panelOrigin")
        UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: "panelSizeV2")
    }

    func setActivity(_ snapshot: ActivitySnapshot) {
        statusLabel.stringValue = snapshot.title
        dot.textColor = snapshot.status == .running ? green : (snapshot.status == .idle ? blue : amber)
    }
    func setUsage(_ snapshot: UsageSnapshot) {
        periodLabel.stringValue = snapshot.period
        percentageLabel.stringValue = "\(Int(snapshot.usedPercent.rounded()))%"
        progress.doubleValue = snapshot.usedPercent
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
    func setConnection(_ text: String) { connectionLabel.stringValue = text }
    private func style(_ label: NSTextField, color: NSColor, size: CGFloat, bold: Bool) {
        label.textColor = color; label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
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
    }

    override func mouseUp(with event: NSEvent) { panel?.saveFrame() }
}

private struct UsageSnapshot { let usedPercent: Double; let period: String }

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
        let primary = limits["primary"] as? [String: Any] ?? limits["limit"] as? [String: Any]
        guard let primary else { return nil }
        let used = (primary["usedPercent"] as? NSNumber)?.doubleValue ?? (primary["used_percent"] as? NSNumber)?.doubleValue
        guard let used else { return nil }
        let minutes = (primary["windowDurationMins"] as? NSNumber)?.intValue ?? (primary["window_duration_mins"] as? NSNumber)?.intValue
        let period: String
        if minutes == nil || minutes == 10080 { period = "周用量" }
        else if let minutes, minutes % 1440 == 0 { period = "\(minutes / 1440)天用量" }
        else if let minutes, minutes % 60 == 0 { period = "\(minutes / 60)小时用量" }
        else { period = "\(minutes!)分钟用量" }
        return UsageSnapshot(usedPercent: min(100, max(0, used)), period: period)
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

private struct SessionMonitor {
    func scan() -> ActivitySnapshot {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = root.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return ActivitySnapshot(status: .unknown, title: "未找到 Codex 会话") }
        let paths = (enumerator.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" }
        let latest = paths.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.prefix(60)
        var active = 0
        var stale = 0
        let now = Date()
        for path in latest where path.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) else { continue }
            var lastLifecycle: String?
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["type"] as? String == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      let type = payload["type"] as? String,
                      ["task_started", "task_complete", "turn_aborted"].contains(type) else { continue }
                lastLifecycle = type
            }
            guard lastLifecycle == "task_started" else { continue }
            let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) <= 12 * 3600 { active += 1 } else { stale += 1 }
        }
        if active > 0 { return ActivitySnapshot(status: .running, title: active == 1 ? "执行中" : "执行中 × \(active)") }
        if stale > 0 { return ActivitySnapshot(status: .unknown, title: "状态未知") }
        return ActivitySnapshot(status: .idle, title: "空闲")
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
