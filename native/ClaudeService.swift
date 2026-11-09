import AppKit
import WebKit
import CryptoKit

/// One plan meter as the server reports it, before stored history is attached.
struct ClaudeLimit {
    let id: String
    let name: String
    let durationMinutes: Double
    let used: Double
    let resetAt: Double?
    var severity: String? = nil
    var active: Bool? = nil
}

/// Reads the usage body shared by Claude Code's get_usage and claude.ai's usage endpoint.
enum ClaudeUsage {
    /// Prefers the server's limits[] rows, classified by kind and never by label,
    /// and falls back to the older top-level keys when a body has no rows.
    static func limits(_ body: [String: Any]) -> [ClaudeLimit] {
        var result: [ClaudeLimit] = []
        for row in body["limits"] as? [[String: Any]] ?? [] {
            if let limit = limit(row), !result.contains(where: { $0.id == limit.id }) { result.append(limit) }
        }
        return result.isEmpty ? legacy(body) : result
    }
    private static func limit(_ row: [String: Any]) -> ClaudeLimit? {
        guard let kind = row["kind"] as? String, let percent = number(row["percent"]) else { return nil }
        let group = row["group"] as? String ?? (kind == "session" ? "session" : kind.hasPrefix("weekly") ? "weekly" : "")
        let minutes: Double
        switch group {
        case "session": minutes = 300
        case "weekly": minutes = 10080
        default: return nil
        }
        let scope = row["scope"] as? [String: Any]
        let scoped = ((scope?["model"] as? [String: Any])?["display_name"] as? String) ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
        let id: String, name: String
        if kind == "session" && scoped == nil { id = "claude:five_hour"; name = "claude" }
        else if kind == "weekly_all" && scoped == nil { id = "claude:seven_day"; name = "claude" }
        else {
            guard let label = scoped ?? row["label"] as? String, !label.isEmpty else { return nil }
            id = "claude:\(group):\(slug(label))"; name = label
        }
        return ClaudeLimit(id: id, name: name, durationMinutes: minutes, used: percent, resetAt: date(row["resets_at"]),
                           severity: row["severity"] as? String, active: row["is_active"] as? Bool)
    }
    private static func legacy(_ body: [String: Any]) -> [ClaudeLimit] {
        let keys: [(key: String, id: String, name: String, minutes: Double)] = [
            ("five_hour", "claude:five_hour", "claude", 300), ("seven_day", "claude:seven_day", "claude", 10080),
            ("seven_day_opus", "claude:weekly:opus", "Opus", 10080), ("seven_day_sonnet", "claude:weekly:sonnet", "Sonnet", 10080)
        ]
        var result = keys.compactMap { entry -> ClaudeLimit? in
            guard let item = body[entry.key] as? [String: Any], let used = number(item["utilization"]) else { return nil }
            return ClaudeLimit(id: entry.id, name: entry.name, durationMinutes: entry.minutes, used: used, resetAt: date(item["resets_at"]))
        }
        for item in body["model_scoped"] as? [[String: Any]] ?? [] {
            guard let label = item["display_name"] as? String, !label.isEmpty, let used = number(item["utilization"]) else { continue }
            let id = "claude:weekly:" + slug(label)
            if !result.contains(where: { $0.id == id }) {
                result.append(ClaudeLimit(id: id, name: label, durationMinutes: 10080, used: used, resetAt: date(item["resets_at"])))
            }
        }
        return result
    }

    static func extra(_ body: [String: Any]) -> ExtraUsage? {
        if let spend = body["spend"] as? [String: Any], let enabled = spend["enabled"] as? Bool {
            return ExtraUsage(enabled: enabled, used: money(spend["used"]), limit: money(spend["limit"]),
                              currency: (spend["used"] as? [String: Any])?["currency"] as? String, percent: number(spend["percent"]))
        }
        if let extra = body["extra_usage"] as? [String: Any], let enabled = extra["is_enabled"] as? Bool {
            return ExtraUsage(enabled: enabled, percent: number(extra["utilization"]))
        }
        return nil
    }
    static func breakdown(_ body: [String: Any]) -> [UsageShare]? {
        guard let rows = (body["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] else { return nil }
        let shares = rows.compactMap { row -> UsageShare? in
            guard let name = row["display_name"] as? String, !name.isEmpty, let percent = number(row["percent"]) else { return nil }
            return UsageShare(name: name, percent: min(100, max(0, percent)))
        }
        return shares.isEmpty ? nil : shares
    }

    /// Attaches stored history to fresh limits. A window with no reset time has not started yet.
    static func merge(_ limits: [ClaudeLimit], into previous: Snapshot, account: String, now: Double) -> [Quota] {
        let history = previous.accountKey == account ? previous.windows : []
        var windows: [Quota] = []
        for limit in limits {
            let used = min(100, max(0, limit.used)), minutes = limit.durationMinutes
            guard let rawReset = limit.resetAt else {
                windows.append(Quota(id: limit.id, name: limit.name, durationMinutes: minutes, resetAt: now + minutes * 60, remaining: 100 - used,
                                     observedAt: now, points: [], severity: limit.severity, active: limit.active, idle: true))
                continue
            }
            guard rawReset > now - 300 else { continue }
            let reset = minute(rawReset)
            let old = history.first { $0.id == limit.id && !$0.isIdle && $0.durationMinutes == minutes && sameCycle($0.resetAt, reset) }
            let stableReset = minute(old?.resetAt ?? reset)
            var points = (old?.points ?? []).filter { $0.t >= stableReset - minutes * 60 && $0.t <= now }
            let sample = Sample(t: now, remaining: 100 - used)
            if let last = points.last, Int(last.t / 60) == Int(now / 60) { points[points.count - 1] = sample } else { points.append(sample) }
            windows.append(Quota(id: limit.id, name: limit.name, durationMinutes: minutes, resetAt: stableReset, remaining: 100 - used,
                                 observedAt: now, points: points, severity: limit.severity, active: limit.active))
        }
        return windows.sorted { $0.id < $1.id }
    }
    // Reset times jitter by fractions of a second between reads (.539 -> .340 -> .235 observed),
    // so cycles match within a tolerance and are stored on whole minutes. A real
    // rollover moves the reset by five hours or a week, far outside this tolerance.
    static func sameCycle(_ previous: Double, _ next: Double) -> Bool { abs(previous - next) < 90 }
    static func minute(_ timestamp: Double) -> Double { (timestamp / 60).rounded() * 60 }
    static func accountKey(_ organization: String) -> String {
        SHA256.hash(data: Data(organization.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
    static func date(_ value: Any?) -> Double? {
        if let seconds = number(value) { return seconds > 0 ? seconds : nil }
        guard let text = value as? String else { return nil }
        // Fractional seconds arrive with up to six digits; parse them apart from the timestamp.
        var base = text, fraction = 0.0
        if let dot = text.firstIndex(of: "."), let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) {
            fraction = Double("0" + text[dot..<end]) ?? 0
            base = String(text[..<dot] + text[end...])
        }
        return iso.date(from: base).map { $0.timeIntervalSince1970 + fraction }
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func money(_ value: Any?) -> Double? {
        guard let amount = value as? [String: Any], let minor = number(amount["amount_minor"]) else { return nil }
        return minor / pow(10, number(amount["exponent"]) ?? 2)
    }
    private static func slug(_ label: String) -> String {
        String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}

/// Runs the bundled reader, which asks the signed-in Claude Code for plan usage without a model turn.
enum ClaudeCLI {
    enum Outcome {
        case reading(organization: String, plan: String?, usage: [String: Any])
        case failure(String)
        case authenticationRequired(String)
    }
    @MainActor static func read(directory: URL, completion: @escaping @MainActor (Outcome) -> Void) {
        guard let helper = Bundle.main.url(forResource: "claude_usage", withExtension: "py") else {
            completion(.failure("The Claude usage reader is missing from this app.")); return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-I", helper.path, "--cwd", directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        task.environment = environment
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { completion(.failure("Unable to start the Claude usage reader.")); return }
        // Two 30-second reads, one retry delay, and process cleanup fit inside this bound.
        DispatchQueue.main.asyncAfter(deadline: .now() + 75) { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let outcome = parse(data)
            Task { @MainActor in completion(outcome) }
        }
    }
    static func parse(_ data: Data) -> Outcome {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure("Claude Code returned no usage data.")
        }
        guard object["ok"] as? Bool == true else {
            let message = object["error"] as? String ?? "Unable to read Claude usage."
            return object["errorCode"] as? String == "auth_required" ? .authenticationRequired(message) : .failure(message)
        }
        guard let usage = object["usage"] as? [String: Any], let organization = object["organization"] as? String,
              (8...100).contains(organization.count) else { return .failure("Claude Code returned incomplete usage data.") }
        return .reading(organization: organization, plan: object["plan"] as? String, usage: usage)
    }
}

/// Whether a Claude read is in flight, and through which path. Every way a read can end
/// (data, failure, timeout, a sign-in started by hand, a stalled reader) returns it to idle.
struct ClaudeReadState {
    enum Phase { case idle, cli, web }
    /// The CLI watchdog (75 s) plus the web wait (25 s), with margin.
    static let staleAfter: Double = 120
    private(set) var phase = Phase.idle
    private(set) var generation = 0
    private var startedAt: Double = 0
    var reading: Bool { phase != .idle }
    var awaitingWeb: Bool { phase == .web }
    /// Starts a read unless one is genuinely in flight; a read past the stale bound is abandoned.
    mutating func begin(now: Double) -> Bool {
        guard phase == .idle || now - startedAt >= Self.staleAfter else { return false }
        phase = .cli; startedAt = now; generation += 1; return true
    }
    /// Late answers from an abandoned read are ignored.
    func isCurrent(_ read: Int) -> Bool { read == generation && reading }
    mutating func fallBackToWeb() { phase = .web }
    /// The connection window takes over from a background web wait, so that wait ends here.
    @discardableResult mutating func signInStarted() -> Bool {
        guard phase == .web else { return false }
        phase = .idle; return true
    }
    mutating func finish() { phase = .idle }
}

@MainActor final class ClaudeService: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let directory: URL
    private let onUpdate: (Snapshot) -> Void
    private var webView: WKWebView!
    private var loginWindow: NSWindow?
    private var lastURL: String?
    private var hasLoaded = false
    private var state = ClaudeReadState()
    private var previous = Snapshot()
    private var cliNeedsAuthentication = false
    private var timeout: DispatchWorkItem?
    private let usagePage = URL(string: "https://claude.ai/settings/usage")!

    init(directory: URL, onUpdate: @escaping (Snapshot) -> Void) {
        self.directory = directory; self.onUpdate = onUpdate
        super.init()
        if let bytes = try? Data(contentsOf: directory.appendingPathComponent("claude-state.json")),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes) { previous = snapshot }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(self, name: "quotaObservation")
        let script = Self.observationScript
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self
        // Use the site's own authenticated page; no credentials are copied from other apps.
    }

    func showConnection() {
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 740), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "Connect Claude · Email sign-in"
            let container = NSView()
            let bar = NSStackView()
            bar.orientation = .horizontal; bar.spacing = 12
            let label = NSTextField(wrappingLabelWithString: "Use Claude email sign-in here. Google passkeys and two-step verification require a regular browser.")
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            let email = NSButton(title: "Email sign-in", target: self, action: #selector(emailLogin))
            let browser = NSButton(title: "Open in browser", target: self, action: #selector(openInBrowser))
            bar.addArrangedSubview(label); bar.addArrangedSubview(email); bar.addArrangedSubview(browser)
            container.addSubview(bar); container.addSubview(webView)
            bar.translatesAutoresizingMaskIntoConstraints = false; webView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                webView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            window.contentView = container; window.isReleasedWhenClosed = false; window.center()
            loginWindow = window
        }
        loginWindow!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !hasLoaded { hasLoaded = true; webView.load(URLRequest(url: usagePage)) }
        else if webView.url?.host != "claude.ai" { emailLogin() }
        else if webView.url?.host == "claude.ai", webView.url?.path == "/new" { webView.load(URLRequest(url: usagePage)) }
    }

    @objc private func emailLogin() {
        timeout?.cancel(); hasLoaded = true
        // Without its timeout, a pending web read would otherwise block every later refresh.
        if state.signInStarted() { onUpdate(previous) }
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login?returnTo=%2Fsettings%2Fusage")!))
    }
    @objc private func openInBrowser() {
        NSWorkspace.shared.open(usagePage)
    }
    private func explainGoogleLogin() {
        let alert = NSAlert()
        alert.messageText = "Google sign-in requires a regular browser"
        alert.informativeText = "Choose Continue with email and use your existing Claude email address. Open the emailed link in another browser, then enter the verification code in this window."
        alert.addButton(withTitle: "Email sign-in")
        alert.addButton(withTitle: "Cancel")
        if let loginWindow { alert.beginSheetModal(for: loginWindow) { [weak self] response in if response == .alertFirstButtonReturn { self?.emailLogin() } } }
    }

    /// Claude Code is the primary source; the claude.ai page is used only when it cannot answer.
    func refresh() {
        guard state.begin(now: Date().timeIntervalSince1970) else { return }
        timeout?.cancel()
        let read = state.generation
        cliNeedsAuthentication = false
        ClaudeCLI.read(directory: directory) { [weak self] outcome in
            guard let self, self.state.isCurrent(read) else { return }
            switch outcome {
            case .reading(let organization, let plan, let usage):
                if !self.ingest(usage, organization: organization, source: "Claude Code", plan: plan) {
                    self.refreshWeb(fallback: "Claude Code reported no plan limits.", read: read)
                }
            case .failure(let message):
                self.refreshWeb(fallback: message, read: read)
            case .authenticationRequired(let message):
                self.cliNeedsAuthentication = true
                self.refreshWeb(fallback: message, read: read, code: "auth_required")
            }
        }
    }
    private func refreshWeb(fallback message: String, read: Int, code: String = "unavailable") {
        let connected = hasLoaded || UserDefaults.standard.bool(forKey: "claudeWebConnected") || previous.source == "claude.ai" || (previous.source == nil && !previous.windows.isEmpty)
        guard connected else { report(message, code: code); return }
        state.fallBackToWeb()
        if !hasLoaded {
            hasLoaded = true; webView.load(URLRequest(url: usagePage))
        } else {
            webView.evaluateJavaScript("window.gaugeRefreshUsage ? window.gaugeRefreshUsage() : false") { [weak self] value, _ in
                guard let self else { return }
                if (value as? Bool) != true, self.lastURL != nil { self.webView.reload() }
            }
        }
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.awaitingWeb, self.state.isCurrent(read) else { return }
            // A timed-out web fallback is not proof that every available connection is signed out.
            self.report(message + " The web connection did not respond either; open Account to reconnect.")
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // A background page must not overwrite a newer Claude Code observation.
        guard state.awaitingWeb || (!state.reading && loginWindow?.isVisible == true),
              message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.host == "claude.ai",
              let payload = message.body as? [String: Any],
              let organization = payload["organization"] as? String,
              organization.count >= 8 && organization.count <= 100,
              let body = payload["body"] as? [String: Any],
              ingest(body, organization: organization, source: "claude.ai", plan: nil) else { return }
        lastURL = payload["path"] as? String
        UserDefaults.standard.set(true, forKey: "claudeWebConnected")
        loginWindow?.title = "Claude connected · Usage Gauge is ready"
    }

    @discardableResult private func ingest(_ body: [String: Any], organization: String, source: String, plan: String?) -> Bool {
        let account = ClaudeUsage.accountKey(organization), now = Date().timeIntervalSince1970
        let windows = ClaudeUsage.merge(ClaudeUsage.limits(body), into: previous, account: account, now: now)
        guard !windows.isEmpty else { return false }
        var snapshot = Snapshot(); snapshot.accountKey = account; snapshot.fetchedAt = now; snapshot.windows = windows
        snapshot.source = source; snapshot.plan = plan ?? (previous.accountKey == account ? previous.plan : nil)
        snapshot.extra = ClaudeUsage.extra(body); snapshot.breakdown = ClaudeUsage.breakdown(body)
        previous = snapshot; timeout?.cancel(); state.finish()
        persist(snapshot); onUpdate(snapshot)
        return true
    }
    private func persist(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: directory.appendingPathComponent("claude-state.json"), options: .atomic) }
    }
    private func report(_ message: String, code: String = "unavailable") {
        timeout?.cancel(); state.finish()
        var value = previous; value.error = message; value.errorCode = code
        previous = value; persist(value); onUpdate(value)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if state.awaitingWeb, cliNeedsAuthentication, webView.url?.host == "claude.ai", webView.url?.path.hasPrefix("/login") == true {
            report("Sign in to Claude Code or reconnect the Claude account.", code: "auth_required"); return
        }
        if webView.url?.host == "claude.ai", ["/new", "/chats", "/"].contains(webView.url?.path ?? "") {
            webView.load(URLRequest(url: usagePage))
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard state.awaitingWeb, (error as NSError).code != NSURLErrorCancelled else { return }
        report("Unable to load the Claude connection page. Try again or sign in to Claude Code.")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.host == "accounts.google.com" {
            decisionHandler(.cancel); explainGoogleLogin(); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url?.host == "accounts.google.com" { explainGoogleLogin(); return nil }
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }

    // Forwards the whole usage body so the page and Claude Code share one parser.
    static let observationScript = #"""
    (() => {
      if (location.hostname !== 'claude.ai') return;
      let usageURL = null;
      const originalFetch = window.fetch.bind(window);
      function accept(url, value) {
        try {
          const target = new URL(url, location.origin);
          const route = target.pathname.match(/^\/api\/organizations\/([^/]+)\/usage\/?$/);
          if (target.origin !== 'https://claude.ai' || !route || !value || typeof value !== 'object') return;
          if (!['limits', 'five_hour', 'seven_day'].some(key => key in value)) return;
          usageURL = target.pathname;
          window.webkit.messageHandlers.quotaObservation.postMessage({organization:route[1], path:usageURL, body:value});
        } catch (_) {}
      }
      window.fetch = async (...args) => {
        const response = await originalFetch(...args);
        if (response.ok && response.url.includes('/usage')) response.clone().json().then(value=>accept(response.url,value)).catch(()=>{});
        return response;
      };
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) {
        this.addEventListener('load', () => {
          if (this.status !== 200 || !this.responseURL.includes('/usage')) return;
          try { accept(this.responseURL, this.responseType === 'json' ? this.response : JSON.parse(this.responseText)); } catch (_) {}
        });
        return send.apply(this,args);
      };
      window.gaugeRefreshUsage = () => {
        if (!usageURL) return false;
        originalFetch(usageURL,{credentials:'same-origin',cache:'no-store'}).then(r=>r.ok?r.json():null).then(v=>accept(usageURL,v)).catch(()=>{});
        return true;
      };
    })();
    """#
}
