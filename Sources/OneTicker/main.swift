import Cocoa
import ServiceManagement

// MARK: - Constants
/// How often to poll while the instrument's exchange is open.
private let kRefreshInterval: TimeInterval = 60
/// How often to poll while it is closed. The stored session belongs to a past day,
/// so the app must keep asking, slowly, to learn when the next one starts.
private let kClosedInterval:  TimeInterval = 900
/// Timer cadence. Actual fetching is gated on the two intervals above.
private let kTickInterval:    TimeInterval = 60
private let kRequestTimeout:  TimeInterval = 15
/// Yahoo throttles the crumb endpoint hard; back off rather than dig the hole deeper.
private let kCrumbBackoffBase: TimeInterval = 60
private let kCrumbBackoffCap:  TimeInterval = 900

private let kLockPath = (NSHomeDirectory() as NSString).appendingPathComponent(".oneticker.lock")
private let kAppName  = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "OneTicker"

// MARK: - Markets
// Suffixes taken from Yahoo Finance's published exchange list:
// https://help.yahoo.com/kb/exchanges-data-providers-yahoo-finance-sln2310.html
// US listings (NASDAQ / NYSE) carry no suffix on Yahoo, hence the single entry.
struct Market {
    let id:     String
    let name:   String
    let suffix: String
}

let kMarkets: [Market] = [
    Market(id: "xetra",      name: "Deutsche Börse (Xetra)",        suffix: ".DE"),
    Market(id: "frankfurt",  name: "Frankfurt Stock Exchange",      suffix: ".F"),
    Market(id: "lse",        name: "London Stock Exchange",         suffix: ".L"),
    Market(id: "paris",      name: "Euronext Paris",                suffix: ".PA"),
    Market(id: "amsterdam",  name: "Euronext Amsterdam",            suffix: ".AS"),
    Market(id: "brussels",   name: "Euronext Brussels",             suffix: ".BR"),
    Market(id: "lisbon",     name: "Euronext Lisbon",               suffix: ".LS"),
    Market(id: "six",        name: "SIX Swiss Exchange",            suffix: ".SW"),
    Market(id: "milan",      name: "Borsa Italiana (Milan)",        suffix: ".MI"),
    Market(id: "madrid",     name: "Bolsa de Madrid (BME)",         suffix: ".MC"),
    Market(id: "vienna",     name: "Vienna Stock Exchange",         suffix: ".VI"),
    Market(id: "stockholm",  name: "Nasdaq Stockholm",              suffix: ".ST"),
    Market(id: "oslo",       name: "Oslo Børs",                     suffix: ".OL"),
    Market(id: "copenhagen", name: "Nasdaq Copenhagen",             suffix: ".CO"),
    Market(id: "helsinki",   name: "Nasdaq Helsinki",               suffix: ".HE"),
    Market(id: "us",         name: "United States (NASDAQ / NYSE)", suffix: ""),
]

// MARK: - Number formatting
// Locale-aware: a price reads "1.431,00" in Zagreb and "1,431.00" in London.
private func makeFormatter(signed: Bool) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle           = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    f.usesGroupingSeparator = true
    if signed { f.positivePrefix = "+" }
    return f
}
private let kPlainFormatter  = makeFormatter(signed: false)
private let kSignedFormatter = makeFormatter(signed: true)

private func fmt(_ v: Double) -> String {
    kPlainFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
}
private func fmtSigned(_ v: Double) -> String {
    kSignedFormatter.string(from: NSNumber(value: v)) ?? String(format: "%+.2f", v)
}

/// "every minute" / "every 10 minutes", derived from the constant so the About
/// panel cannot drift out of step with the actual timer.
private func refreshPhrase() -> String {
    if kRefreshInterval < 60 { return "every \(Int(kRefreshInterval)) seconds" }
    let minutes = Int((kRefreshInterval / 60).rounded())
    return minutes == 1 ? "every minute" : "every \(minutes) minutes"
}

// MARK: - Settings (persisted in UserDefaults)
enum Settings {
    private static let kSymbolKey = "tickerSymbol"
    private static let kMarketKey = "marketID"

    static var symbol: String {
        get {
            let s = (UserDefaults.standard.string(forKey: kSymbolKey) ?? "SAP")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return s.isEmpty ? "SAP" : s
        }
        set { UserDefaults.standard.set(newValue, forKey: kSymbolKey) }
    }

    static var market: Market {
        get {
            let id = UserDefaults.standard.string(forKey: kMarketKey) ?? "xetra"
            return kMarkets.first { $0.id == id } ?? kMarkets[0]
        }
        set { UserDefaults.standard.set(newValue.id, forKey: kMarketKey) }
    }

    /// The symbol as Yahoo Finance expects it, e.g. "SAP" + ".DE" -> "SAP.DE".
    static var yahooSymbol: String { symbol + market.suffix }
}

// MARK: - Single-instance lock
nonisolated(unsafe) private var lockFD: Int32 = -1

private func acquireLock() -> Bool {
    lockFD = open(kLockPath, O_WRONLY | O_CREAT, 0o644)
    guard lockFD >= 0 else { return false }
    return flock(lockFD, LOCK_EX | LOCK_NB) == 0
}

// MARK: - Yahoo Finance
private struct StockInfo: Sendable {
    let price:         Double
    let previousClose: Double
    let currency:      String
    /// Regular trading session for this instrument's own exchange, in epoch seconds.
    let sessionStart:  TimeInterval?
    let sessionEnd:    TimeInterval?
}

private enum FetchError: Int {
    case parse       = 1
    case noCrumb     = 2
    case badURL      = 3
    case badSymbol   = 4
    case backingOff  = 5
    case httpStatus  = 6
}

private func err(_ kind: FetchError, _ message: String) -> NSError {
    NSError(domain: "OneTicker", code: kind.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message])
}

/// The crumb is touched from both the main thread and URLSession's background
/// threads, so it lives behind a serial queue rather than as a bare global.
private final class CrumbStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.petrakovic.oneticker.crumb")
    private var value: String?
    private var failures = 0
    private var blockedUntil: TimeInterval = 0

    var current: String? { queue.sync { value } }

    /// Seconds still to wait before another crumb attempt is worth making.
    var backoffRemaining: TimeInterval {
        queue.sync { max(0, blockedUntil - Date().timeIntervalSince1970) }
    }

    func store(_ crumb: String) {
        queue.sync { value = crumb; failures = 0; blockedUntil = 0 }
    }

    func recordFailure() {
        queue.sync {
            failures += 1
            let delay = min(kCrumbBackoffCap,
                            kCrumbBackoffBase * pow(2, Double(failures - 1)))
            blockedUntil = Date().timeIntervalSince1970 + delay
        }
    }

    func invalidate() { queue.sync { value = nil } }
}
private let crumbStore = CrumbStore()

private let kHeaders = [
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
]

private func makeRequest(_ urlString: String) -> URLRequest? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url,
                         cachePolicy: .reloadIgnoringLocalCacheData,
                         timeoutInterval: kRequestTimeout)
    kHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    return req
}

private func isOK(_ response: URLResponse?) -> Bool {
    guard let http = response as? HTTPURLResponse else { return false }
    return (200...299).contains(http.statusCode)
}

private func fetchCrumb(_ completion: @escaping (String?) -> Void) {
    guard let initReq = makeRequest("https://fc.yahoo.com") else { completion(nil); return }
    URLSession.shared.dataTask(with: initReq) { _, _, _ in
        guard let crumbReq = makeRequest("https://query2.finance.yahoo.com/v1/test/getcrumb") else {
            completion(nil); return
        }
        URLSession.shared.dataTask(with: crumbReq) { data, response, _ in
            // Under throttling this endpoint answers 429 with the plain text
            // "Too Many Requests". Checking the status is what catches it, and the
            // shape checks below catch the same body served with a 200.
            guard isOK(response),
                  let data  = data,
                  let crumb = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !crumb.isEmpty, crumb.count < 32,
                  !crumb.hasPrefix("{"), !crumb.contains(" ") else {
                completion(nil); return
            }
            crumbStore.store(crumb)
            completion(crumb)
        }.resume()
    }.resume()
}

private func fetchStock(symbol: String, _ completion: @escaping (Result<StockInfo, Error>) -> Void) {
    func doFetch(crumb: String) {
        let encodedCrumb  = crumb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? crumb
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let req = makeRequest(
            "https://query2.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)?interval=1d&range=1d&crumb=\(encodedCrumb)"
        ) else {
            completion(.failure(err(.badURL, "Invalid URL")))
            return
        }
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = json["chart"] as? [String: Any] else {
                // A throttled or expired-crumb response is not JSON at all.
                completion(.failure(isOK(response)
                    ? err(.parse, "Parse error")
                    : err(.httpStatus, "Yahoo refused the request")))
                return
            }
            // Yahoo reports an unknown symbol as chart.error, not as a malformed body.
            if let e = chart["error"] as? [String: Any],
               let desc = e["description"] as? String {
                completion(.failure(err(.badSymbol, desc)))
                return
            }
            guard let results   = chart["result"] as? [[String: Any]],
                  let meta      = results.first?["meta"] as? [String: Any],
                  let price     = meta["regularMarketPrice"] as? Double,
                  let prevClose = meta["chartPreviousClose"] as? Double,
                  let currency  = meta["currency"]           as? String
            else {
                completion(.failure(err(.parse, "Parse error")))
                return
            }
            let regular = (meta["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any]
            completion(.success(StockInfo(
                price:         price,
                previousClose: prevClose,
                currency:      currency,
                sessionStart:  regular?["start"] as? TimeInterval,
                sessionEnd:    regular?["end"]   as? TimeInterval)))
        }.resume()
    }

    if let crumb = crumbStore.current {
        doFetch(crumb: crumb)
        return
    }
    let wait = crumbStore.backoffRemaining
    guard wait == 0 else {
        completion(.failure(err(.backingOff,
            "Rate limited by Yahoo, retrying in \(Int(wait.rounded()))s")))
        return
    }
    fetchCrumb { crumb in
        guard let crumb = crumb else {
            crumbStore.recordFailure()
            completion(.failure(err(.noCrumb, "Could not reach Yahoo")))
            return
        }
        doFetch(crumb: crumb)
    }
}

/// An accessory (menu bar only) app has to activate itself before a window
/// it opens will come to the front.
func activateApp() {
    if #available(macOS 14.0, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
}

// MARK: - Launch at login
/// SMAppService registers the app with the system by bundle identity, so unlike a
/// hand-added login item it cannot be left dangling when the app is renamed or moved.
/// A stale "SAP Ticker" entry pointing at a deleted bundle is exactly what this avoids.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The app was in the user's login items under its previous name. Renaming the
    /// bundle orphaned that entry, silently, and it only showed up at the next reboot.
    /// Restore the behaviour once; after that the checkbox owns it.
    static func restoreOnce() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if let problem = set(true) {
            NSLog("[OneTicker] could not register login item: %@", problem)
        }
    }

    /// Returns nil on success, or a message to show the user.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Settings window
final class SettingsWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private var window:       NSWindow!
    private var marketPopUp:  NSPopUpButton!
    private var symbolField:  NSTextField!
    private var previewLabel: NSTextField!
    private var launchAtLogin: NSButton!
    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init()
        buildWindow()
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 286),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        guard let content = window.contentView else { return }

        content.addSubview(label("Market:", NSRect(x: 24, y: 230, width: 70, height: 18), align: .right))
        marketPopUp = NSPopUpButton(frame: NSRect(x: 102, y: 225, width: 314, height: 26), pullsDown: false)
        marketPopUp.addItems(withTitles: kMarkets.map { $0.name })
        marketPopUp.target = self
        marketPopUp.action = #selector(inputChanged)
        content.addSubview(marketPopUp)

        content.addSubview(label("Symbol:", NSRect(x: 24, y: 192, width: 70, height: 18), align: .right))
        symbolField = NSTextField(frame: NSRect(x: 102, y: 189, width: 160, height: 24))
        symbolField.placeholderString = "e.g. SAP"
        symbolField.delegate = self
        content.addSubview(symbolField)

        previewLabel = label("", NSRect(x: 102, y: 158, width: 314, height: 18), secondary: true)
        content.addSubview(previewLabel)

        let hint = label("Enter the plain symbol without an exchange suffix. The suffix for the\nselected market is added automatically.",
                         NSRect(x: 24, y: 110, width: 392, height: 34), secondary: true)
        hint.lineBreakMode        = .byWordWrapping
        hint.maximumNumberOfLines = 2
        content.addSubview(hint)

        // Applies immediately rather than on Save, matching how System Settings
        // treats login items. Cancel deliberately does not revert it.
        launchAtLogin = NSButton(checkboxWithTitle: "Open OneTicker at login",
                                 target: self, action: #selector(launchAtLoginToggled))
        launchAtLogin.frame = NSRect(x: 102, y: 66, width: 314, height: 20)
        content.addSubview(launchAtLogin)

        let cancel = NSButton(frame: NSRect(x: 232, y: 16, width: 90, height: 32))
        cancel.title         = "Cancel"
        cancel.bezelStyle    = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target        = self
        cancel.action        = #selector(cancelClicked)
        content.addSubview(cancel)

        let save = NSButton(frame: NSRect(x: 326, y: 16, width: 90, height: 32))
        save.title         = "Save"
        save.bezelStyle    = .rounded
        save.keyEquivalent = "\r"
        save.target        = self
        save.action        = #selector(saveClicked)
        content.addSubview(save)
    }

    private func label(_ text: String, _ frame: NSRect,
                       align: NSTextAlignment = .left,
                       secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame     = frame
        l.alignment = align
        if secondary {
            l.font      = NSFont.systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
        }
        return l
    }

    func show() {
        // Load current values every time the window opens.
        if let idx = kMarkets.firstIndex(where: { $0.id == Settings.market.id }) {
            marketPopUp.selectItem(at: idx)
        }
        symbolField.stringValue = Settings.symbol
        launchAtLogin.state = LoginItem.isEnabled ? .on : .off
        updatePreview()

        activateApp()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(symbolField)
    }

    /// Uppercases, trims, and strips a suffix the user may have typed by hand.
    private func normalizedSymbol() -> String {
        var s = symbolField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let suffix = selectedMarket().suffix
        if !suffix.isEmpty, s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s
    }

    private func selectedMarket() -> Market {
        let idx = marketPopUp.indexOfSelectedItem
        return (idx >= 0 && idx < kMarkets.count) ? kMarkets[idx] : kMarkets[0]
    }

    private func updatePreview() {
        let s = normalizedSymbol()
        previewLabel.stringValue = s.isEmpty ? "" : "Yahoo symbol:  \(s + selectedMarket().suffix)"
    }

    @objc private func launchAtLoginToggled() {
        let wanted = launchAtLogin.state == .on
        guard let problem = LoginItem.set(wanted) else { return }
        // Failed: put the checkbox back where it was and say why.
        launchAtLogin.state = wanted ? .off : .on
        let alert = NSAlert()
        alert.messageText     = "Could not change the login item"
        alert.informativeText = problem
        alert.alertStyle      = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func inputChanged() { updatePreview() }

    func controlTextDidChange(_ note: Notification) { updatePreview() }

    @objc private func cancelClicked() { window.orderOut(nil) }

    @objc private func saveClicked() {
        let symbol = normalizedSymbol()
        guard !symbol.isEmpty else {
            NSSound.beep()
            window.makeFirstResponder(symbolField)
            return
        }
        Settings.symbol = symbol
        Settings.market = selectedMarket()
        window.orderOut(nil)
        onSave()
    }
}

// MARK: - App delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem:     NSStatusItem!
    private var priceMenuItem:  NSMenuItem!
    private var changeMenuItem: NSMenuItem!
    private var marketMenuItem: NSMenuItem!
    private var timer: Timer?
    private var settingsController: SettingsWindowController?

    /// Regular session for the current instrument, as reported by Yahoo.
    private var sessionStart: TimeInterval?
    private var sessionEnd:   TimeInterval?
    private var lastFetchAt:  TimeInterval = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\(Settings.symbol) …"

        priceMenuItem  = makeDisplayItem("Loading…",   symbol: "tag")
        changeMenuItem = makeDisplayItem("",           symbol: "chart.line.uptrend.xyaxis")
        marketMenuItem = makeDisplayItem(marketLabel(), symbol: "building.columns")

        let menu = NSMenu()
        // Enablement is set per item below, so AppKit must not recompute it.
        menu.autoenablesItems = false
        menu.addItem(priceMenuItem)
        menu.addItem(changeMenuItem)
        menu.addItem(marketMenuItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh now", #selector(manualRefresh), symbol: "arrow.clockwise"))
        menu.addItem(actionItem("Settings…",   #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(actionItem("About \(kAppName)", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(actionItem("Quit", #selector(NSApplication.terminate(_:)), key: "q", symbol: "power"))
        statusItem.menu = menu

        LoginItem.restoreOnce()

        fetchAndUpdate()
        let t = Timer.scheduledTimer(withTimeInterval: kTickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Lets macOS coalesce this with other wakeups instead of firing on the dot.
        t.tolerance = kTickInterval * 0.2
        timer = t
    }

    func applicationWillTerminate(_ note: Notification) {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Scheduling

    private func tick() {
        let open = isMarketOpen()
        marketMenuItem.title = marketLabel(closed: !open)
        // Poll slowly while closed rather than not at all: the stored session is from
        // a past day, and only a fresh response reveals the next one. Skipping this
        // entirely would strand the app after its first market close.
        let due = open ? kRefreshInterval : kClosedInterval
        guard Date().timeIntervalSince1970 - lastFetchAt >= due else { return }
        fetchAndUpdate()
    }

    private func isMarketOpen() -> Bool {
        guard let start = sessionStart, let end = sessionEnd else { return true }
        let now = Date().timeIntervalSince1970
        return now >= start && now <= end
    }

    private func marketLabel(closed: Bool = false) -> String {
        let base = "\(Settings.market.name) · \(Settings.yahooSymbol)"
        return closed ? base + " · closed" : base
    }

    // MARK: Actions

    /// Standard AppKit About panel, same shape as "About This Mac":
    /// name, version, copyright, plus one line on the refresh cadence.
    @objc private func showAbout() {
        activateApp()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        // .applicationVersion is the "Version 2.4.0" line (CFBundleShortVersionString);
        // .version is the "(build)" suffix (CFBundleVersion). Blanking the latter
        // avoids the redundant "Version 2.4.0 (2.4.0)".
        options[.version] = ""

        let style = NSMutableParagraphStyle()
        style.alignment     = .center
        style.lineSpacing   = 2
        // Kept short: the standard panel is narrow and wraps mid-sentence otherwise.
        let text = "Refreshes \(refreshPhrase()) during market hours.\n"
                 + "Prices are delayed by the exchange."
        options[.credits] = NSAttributedString(string: text, attributes: [
            .font:            NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle:  style,
        ])
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController { [weak self] in
                self?.applySettingsChange()
            }
        }
        settingsController?.show()
    }

    private func applySettingsChange() {
        marketMenuItem.title     = marketLabel()
        priceMenuItem.title      = "Loading…"
        changeMenuItem.title     = ""
        statusItem.button?.title = "\(Settings.symbol) …"
        sessionStart = nil
        sessionEnd   = nil
        fetchAndUpdate()
    }

    @objc private func manualRefresh() {
        statusItem.button?.title = "\(Settings.symbol) …"
        fetchAndUpdate()
    }

    // MARK: Fetching

    private func fetchAndUpdate(retryOnParseError: Bool = true) {
        lastFetchAt  = Date().timeIntervalSince1970
        let symbol   = Settings.symbol
        let yahooSym = Settings.yahooSymbol

        fetchStock(symbol: yahooSym) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // A slow response for a previously selected symbol must not overwrite the new one.
                guard yahooSym == Settings.yahooSymbol else { return }

                switch result {
                case .success(let info):
                    self.sessionStart = info.sessionStart
                    self.sessionEnd   = info.sessionEnd
                    self.show(info, symbol: symbol)
                case .failure(let e):
                    if (e as NSError).code == FetchError.parse.rawValue, retryOnParseError {
                        // Most likely an expired crumb, so drop it and try once more.
                        crumbStore.invalidate()
                        self.fetchAndUpdate(retryOnParseError: false)
                    } else {
                        self.showError(e, symbol: symbol)
                    }
                }
            }
        }
    }

    private func show(_ info: StockInfo, symbol: String) {
        let change = info.price - info.previousClose
        let pct    = info.previousClose == 0 ? 0 : change / info.previousClose * 100
        let arrow  = change >= 0 ? "▲" : "▼"

        statusItem.button?.title = "\(symbol)  \(fmt(info.price)) \(info.currency)"
        priceMenuItem.title      = "Price:  \(fmt(info.price)) \(info.currency)"
        changeMenuItem.title     = "\(arrow) \(fmtSigned(change))  (\(fmtSigned(pct))%)"
        marketMenuItem.title     = marketLabel(closed: !isMarketOpen())
    }

    private func showError(_ e: Error, symbol: String) {
        statusItem.button?.title = "\(symbol) ⚠"
        priceMenuItem.title      = String(e.localizedDescription.prefix(60))
        changeMenuItem.title     = ""
    }

    // MARK: Menu construction

    /// AppKit does not pad items that have no image, so a menu where only some
    /// rows carry an icon ends up with two different left edges. Every row here
    /// gets a symbol, which keeps all titles on one edge.
    private func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        return image
    }

    /// A command row.
    private func actionItem(_ title: String,
                            _ selector: Selector,
                            key: String = "",
                            symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.image     = symbolImage(symbol)
        item.isEnabled = true
        return item
    }

    /// A read-only status row.
    private func makeDisplayItem(_ title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image     = symbolImage(symbol)
        item.isEnabled = false
        return item
    }
}

// MARK: - Entry point
guard acquireLock() else { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
