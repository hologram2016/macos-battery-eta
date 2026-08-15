import AppKit
import Foundation

private let bundleID = "com.batteryeta.app"
private let sampleLimit = 10
private let idleMilliamp: Int64 = 80
private let updateInterval: TimeInterval = 20

struct Snapshot {
    var present: Bool
    var charging: Bool
    var external: Bool
    var percent: Int?
    var mAh: Int64?
    var maxMAh: Int64?
    var designMAh: Int64?
    var milliamps: Int64?
    var millivolts: Int64?
    var cycles: Int64?
    var smcMinutes: Int64?
    var tempC: Double?

    var watts: Double? {
        guard let ma = milliamps, let mv = millivolts else { return nil }
        return Double(abs(ma)) * Double(mv) / 1_000_000.0
    }

    var healthPercent: Int? {
        guard let maxMAh, let designMAh, designMAh > 0 else { return nil }
        return Int((Double(maxMAh) / Double(designMAh) * 100.0).rounded())
    }

    /// Negative = pack is discharging.
    var discharging: Bool {
        if let ma = milliamps { return ma <= -idleMilliamp }
        return present && !charging && !external
    }
}

enum Glance {
    case noBattery
    case ac(percent: Int?)
    case settling(percent: Int?)
    case emptyIn(minutes: Int, percent: Int?, drainingOnAC: Bool)

    var title: String {
        switch self {
        case .noBattery:
            return "—"
        case .ac:
            return "AC"
        case .settling(let pct):
            if let pct { return "\(pct)%" }
            return "…"
        case .emptyIn(let minutes, _, _):
            return formatMinutes(minutes)
        }
    }

    var tooltip: String {
        switch self {
        case .noBattery:
            return "No internal battery"
        case .ac(let pct):
            if let pct { return "On power · \(pct)%" }
            return "On power"
        case .settling(let pct):
            if let pct { return "Settling estimate · \(pct)%" }
            return "Settling estimate"
        case .emptyIn(let minutes, let pct, let onAC):
            var parts = ["About \(formatMinutesWords(minutes)) to empty"]
            if let pct { parts.append("\(pct)%") }
            if onAC { parts.append("draining on AC") }
            return parts.joined(separator: " · ")
        }
    }

    var warning: Bool {
        if case .emptyIn(let minutes, _, _) = self { return minutes < 45 }
        return false
    }

    var critical: Bool {
        if case .emptyIn(let minutes, _, _) = self { return minutes < 20 }
        return false
    }
}

func formatMinutes(_ minutes: Int) -> String {
    let m = max(0, minutes)
    if m < 60 { return "\(m)m" }
    return String(format: "%d:%02d", m / 60, m % 60)
}

func formatMinutesWords(_ minutes: Int) -> String {
    let m = max(0, minutes)
    if m < 60 { return "\(m) min" }
    let h = m / 60
    let rem = m % 60
    if rem == 0 { return h == 1 ? "1 hour" : "\(h) hours" }
    return "\(h)h \(rem)m"
}

func signedInt64(_ value: Any?) -> Int64? {
    guard let value else { return nil }
    if let n = value as? Int64 { return n }
    if let n = value as? Int { return Int64(n) }
    if let n = value as? Int32 { return Int64(n) }
    if let n = value as? UInt64 { return Int64(bitPattern: n) }
    if let n = value as? NSNumber {
        let u = n.uint64Value
        if u > UInt64(Int64.max) { return Int64(bitPattern: u) }
        return n.int64Value
    }
    return nil
}

func readBool(_ value: Any?) -> Bool? {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
}

func readBattery() -> Snapshot {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    proc.arguments = ["-rn", "AppleSmartBattery", "-a"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return Snapshot(
            present: false, charging: false, external: false,
            percent: nil, mAh: nil, maxMAh: nil, designMAh: nil,
            milliamps: nil, millivolts: nil, cycles: nil, smcMinutes: nil, tempC: nil
        )
    }
    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard
        let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
        let arr = root as? [[String: Any]],
        let dict = arr.first
    else {
        return Snapshot(
            present: false, charging: false, external: false,
            percent: nil, mAh: nil, maxMAh: nil, designMAh: nil,
            milliamps: nil, millivolts: nil, cycles: nil, smcMinutes: nil, tempC: nil
        )
    }

    let mAh = signedInt64(dict["AppleRawCurrentCapacity"]) ?? signedInt64(dict["CurrentCapacity"])
    let maxMAh = signedInt64(dict["AppleRawMaxCapacity"]) ?? signedInt64(dict["MaxCapacity"])
    let design = signedInt64(dict["DesignCapacity"])
    let ma = signedInt64(dict["InstantAmperage"]) ?? signedInt64(dict["Amperage"])
    var pct: Int?
    if let mAh, let maxMAh, maxMAh > 0 {
        pct = Int((Double(mAh) / Double(maxMAh) * 100.0).rounded())
    }
    var tempC: Double?
    if let t = signedInt64(dict["Temperature"]) {
        tempC = Double(t) / 100.0
    }

    return Snapshot(
        present: true,
        charging: readBool(dict["IsCharging"]) ?? false,
        external: readBool(dict["ExternalConnected"]) ?? false,
        percent: pct,
        mAh: mAh,
        maxMAh: maxMAh,
        designMAh: design,
        milliamps: ma,
        millivolts: signedInt64(dict["Voltage"]),
        cycles: signedInt64(dict["CycleCount"]),
        smcMinutes: signedInt64(dict["TimeRemaining"]),
        tempC: tempC
    )
}

final class Estimator {
    private var samples: [Int64] = []
    private var lastExternal: Bool?
    private var lastCharging: Bool?

    func reset() {
        samples.removeAll()
    }

    func glance(from snap: Snapshot) -> Glance {
        guard snap.present else { return .noBattery }

        if lastExternal != nil && lastExternal != snap.external {
            reset()
        }
        if lastCharging != nil && lastCharging != snap.charging {
            reset()
        }
        lastExternal = snap.external
        lastCharging = snap.charging

        if snap.charging || (snap.external && !snap.discharging) {
            reset()
            return .ac(percent: snap.percent)
        }

        if let ma = snap.milliamps, ma <= -idleMilliamp {
            samples.append(ma)
            if samples.count > sampleLimit {
                samples.removeFirst(samples.count - sampleLimit)
            }
        }

        guard let mAh = snap.mAh, mAh > 0 else {
            return .settling(percent: snap.percent)
        }

        let usable = samples.filter { $0 <= -idleMilliamp }
        guard let med = median(usable), med < 0 else {
            return .settling(percent: snap.percent)
        }

        let minutes = Int((Double(mAh) / Double(-med) * 60.0).rounded())
        return .emptyIn(minutes: minutes, percent: snap.percent, drainingOnAC: snap.external)
    }

    private func median(_ xs: [Int64]) -> Int64? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }
}

func smcLabel(_ snap: Snapshot) -> String {
    guard let m = snap.smcMinutes, m > 0, m < 24 * 60 else { return "—" }
    return formatMinutes(Int(m))
}

func printOnce() {
    let snap = readBattery()
    // --once has no history, so show a one-shot current-based figure when possible.
    let oneShot: String
    if !snap.present {
        oneShot = "no-battery"
    } else if snap.charging || (snap.external && !snap.discharging) {
        oneShot = "AC"
    } else if let mAh = snap.mAh, let ma = snap.milliamps, ma <= -idleMilliamp {
        let minutes = Int((Double(mAh) / Double(-ma) * 60.0).rounded())
        oneShot = formatMinutes(minutes)
    } else if let pct = snap.percent {
        oneShot = "\(pct)%"
    } else {
        oneShot = "unknown"
    }
    print(oneShot)
    if CommandLine.arguments.contains("--verbose") {
        fputs("percent=\(snap.percent.map(String.init) ?? "?") mAh=\(snap.mAh.map(String.init) ?? "?")/\(snap.maxMAh.map(String.init) ?? "?") mA=\(snap.milliamps.map(String.init) ?? "?") smc=\(smcLabel(snap)) charging=\(snap.charging) external=\(snap.external)\n", stderr)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var readyTimer: Timer?
    private let estimator = Estimator()
    private var lastSnap = Snapshot(
        present: false, charging: false, external: false,
        percent: nil, mAh: nil, maxMAh: nil, designMAh: nil,
        milliamps: nil, millivolts: nil, cycles: nil, smcMinutes: nil, tempC: nil
    )
    private var lastGlance: Glance = .noBattery

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        observeSession()
        startWhenMenuBarReady()
    }

    private func dockIsUp() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dock"
        }
    }

    private func startWhenMenuBarReady() {
        if dockIsUp() {
            setupItem()
            return
        }
        let deadline = Date().addingTimeInterval(45)
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            if self.dockIsUp() || Date() > deadline {
                t.invalidate()
                self.readyTimer = nil
                self.setupItem()
            }
        }
        if let readyTimer {
            RunLoop.main.add(readyTimer, forMode: .common)
        }
    }

    private func observeSession() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setupItem()
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setupItem()
        }
    }

    private func setupItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            statusItem = item
        }
        if timer == nil {
            let t = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        refresh()
    }

    @objc private func refresh() {
        lastSnap = readBattery()
        lastGlance = estimator.glance(from: lastSnap)
        apply(lastGlance, lastSnap)
    }

    private func apply(_ glance: Glance, _ snap: Snapshot) {
        guard let button = statusItem?.button else { return }
        let color: NSColor
        if glance.critical {
            color = .systemRed
        } else if glance.warning {
            color = .systemOrange
        } else {
            color = .labelColor
        }
        let title = NSAttributedString(string: glance.title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
        button.attributedTitle = title
        button.toolTip = glance.tooltip
        statusItem?.menu = buildMenu(glance, snap)
    }

    private func buildMenu(_ glance: Glance, _ snap: Snapshot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func info(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        func action(_ text: String, _ selector: Selector) {
            let item = NSMenuItem(title: text, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }

        switch glance {
        case .noBattery:
            info("No internal battery")
        case .ac(let pct):
            if snap.charging {
                info("Charging" + (pct.map { " · \($0)%" } ?? ""))
                info("macOS to full    \(smcLabel(snap))")
            } else {
                info("On power" + (pct.map { " · \($0)%" } ?? ""))
            }
        case .settling(let pct):
            info("Until empty    settling…")
            if let pct { info("Charge         \(pct)%") }
        case .emptyIn(let minutes, let pct, let onAC):
            info("Until empty    \(formatMinutesWords(minutes))")
            if let pct { info("Charge         \(pct)%") }
            if onAC { info("Draining on AC") }
        }

        if snap.present {
            if case .ac = glance {} else {
                info("macOS guess    \(smcLabel(snap))")
            }
            if let mAh = snap.mAh, let maxMAh = snap.maxMAh {
                info(String(format: "Pack           %d / %d mAh", mAh, maxMAh))
            }
            if let ma = snap.milliamps {
                let w = snap.watts.map { String(format: " · %.1f W", $0) } ?? ""
                info(String(format: "Draw           %+d mA%@", ma, w))
            }
            if let health = snap.healthPercent, let cycles = snap.cycles {
                info("Health         \(health)% · \(cycles) cycles")
            }
            if let t = snap.tempC {
                info(String(format: "Pack temp      %.1f °C", t))
            }
        }

        menu.addItem(.separator())
        info("From pack current (smoothed)")
        info("macOS’s first unplug guess is often high")
        menu.addItem(.separator())
        action("Refresh", #selector(refresh))
        action("Battery…", #selector(openEnergy))
        action("Quit Battery ETA", #selector(quit))
        return menu
    }

    @objc private func openEnergy() {
        // Monterey laptops ship Battery.prefPane. EnergySaver.prefPane is an
        // empty stub and System Preferences shows “Could not install (null)”.
        let panes = [
            "/System/Library/PreferencePanes/Battery.prefPane",
            "/System/Library/PreferencePanes/EnergySaverPref.prefPane",
        ]
        if let path = panes.first(where: {
            FileManager.default.fileExists(atPath: $0 + "/Contents/Info.plist")
        }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--once") {
    printOnce()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
