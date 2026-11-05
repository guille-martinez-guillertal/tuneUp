import SwiftUI
import AppKit
import TuneUpCore

@main
struct TuneUpApp: App {
    @StateObject private var model = ScanModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Export report…") { model.export() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

final class ScanModel: ObservableObject {
    @Published var report = Report()
    @Published var busy = false
    @Published var current = "Ready for a baseline scan"
    @Published var progress = 0.0
    @Published var online = true
    @Published var includeEvidence = false
    @Published var message: String?
    @Published var comparison: String?
    private var stopRequested = false
    private let queue = DispatchQueue(label: "TuneUp.diagnostics", qos: .utility)

    func scan() {
        guard !busy else { return }
        report = Report(); stopRequested = false; busy = true; progress = 0
        let probes = Catalog.probes(online: online)
        current = "Inventorying applications, startup software and recent crashes…"
        queue.async {
            let inventory = Catalog.localInventory()
            DispatchQueue.main.async { self.report.observations = inventory }
            for (index, probe) in probes.enumerated() {
                var stop = false
                DispatchQueue.main.sync {
                    stop = self.stopRequested
                    self.current = "\(probe.category): \(probe.title)"
                }
                if stop { break }
                let observation = Runner.run(probe)
                DispatchQueue.main.async {
                    self.report.observations.append(observation)
                    self.progress = Double(index + 1) / Double(probes.count)
                }
            }
            DispatchQueue.main.async {
                self.report.completed = !self.stopRequested
                self.current = self.stopRequested ? "Stopped — partial report retained" : "Scan complete — review findings and evidence"
                self.busy = false
            }
        }
    }

    func stop() { stopRequested = true; current = "Stopping after the current check (updates can take up to three minutes)…" }

    func verifyDisk() {
        guard !busy else { return }
        busy = true; current = "Verifying startup filesystem — this can briefly slow the Mac…"
        queue.async {
            let observation = Runner.run(Probe("filesystem", "Storage", "Startup filesystem verification", "/usr/sbin/diskutil", ["verifyVolume", "/"], timeout: 300))
            DispatchQueue.main.async {
                self.report.observations.removeAll { $0.id == "filesystem" }
                self.report.observations.append(observation)
                self.current = "Disk verification finished — inspect its evidence"
                self.busy = false
            }
        }
    }

    func enableFirewall() {
        guard !busy else { return }
        busy = true; current = "Waiting for macOS administrator authorization…"
        queue.async {
            let action = Runner.run(Probe("firewall-action", "Actions", "Enable firewall", "/usr/bin/osascript", ["-e", "do shell script \"/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on\" with administrator privileges"], timeout: 120))
            let verification = Runner.run(Probe("firewall", "Security", "Application firewall", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]))
            DispatchQueue.main.async {
                self.report.observations.removeAll { $0.id == "firewall" }
                self.report.observations.append(contentsOf: [action, verification])
                self.busy = false
                self.current = verification.output.lowercased().contains("enabled") ? "Firewall is enabled" : "Firewall change was not verified — inspect evidence"
            }
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TuneUp-report.md"
        panel.allowedFileTypes = ["md"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.markdown(includeEvidence: includeEvidence).write(to: url, atomically: true, encoding: .utf8)
            message = "Report saved. Automatic redaction is best effort. Review it before sharing; hostnames, network names and file paths may remain."
        } catch { message = error.localizedDescription }
    }

    func saveBaseline() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TuneUp-private-baseline.json"
        panel.allowedFileTypes = ["json"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = "Private baseline saved. This JSON contains unredacted evidence: keep it on your Mac."
        } catch { message = error.localizedDescription }
    }

    func compare() {
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["json"]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 10_000_000 else { message = "Baseline is too large (limit: 10 MB)."; return }
            let previous = try JSONDecoder().decode(Report.self, from: data)
            let old = previous.findings.filter { $0.severity == .attention }.map { $0.id }
            let new = report.findings.filter { $0.severity == .attention }.map { $0.id }
            let resolved = Set(old).subtracting(new).sorted()
            let added = Set(new).subtracting(old).sorted()
            comparison = "Previous scan: \(previous.generatedAt)\nPrevious complete: \(previous.completed); current complete: \(report.completed)\nNo longer flagged: \(resolved.isEmpty ? "none" : resolved.joined(separator: ", "))\nNew attention items: \(added.isEmpty ? "none" : added.joined(separator: ", "))\nA missing finding does not prove a repair if its check was skipped or failed. Compare evidence."
        } catch { message = "Cannot read baseline: \(error.localizedDescription)" }
    }
}

struct ContentView: View {
    @ObservedObject var model: ScanModel
    @State private var selection = "Overview"
    @State private var search = ""
    @State private var confirmFirewall = false
    @State private var confirmDisk = false
    private let pages = ["Overview", "Findings", "Evidence", "Actions", "Reports"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("TuneUp", systemImage: "waveform.path.ecg").font(.largeTitle.bold())
                Text("Understand your Mac.\nMake deliberate repairs.")
                    .font(.callout).foregroundColor(.secondary)
                ForEach(pages, id: \.self) { page in
                    Button { selection = page } label: {
                        HStack {
                            Image(systemName: icon(page)).frame(width: 24)
                            Text(page)
                            Spacer()
                        }.padding(10)
                            .background(selection == page ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(8)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Local by design\nNo telemetry or cloud upload")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(24).frame(width: 230).background(Color(NSColor.controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(selection).font(.largeTitle.bold())
                        Text(model.current).font(.callout).foregroundColor(.secondary)
                    }
                    Spacer()
                    if model.busy { Button("Stop after check") { model.stop() } }
                    Button(model.report.observations.isEmpty ? "Scan my Mac" : "Run fresh scan") { model.scan() }
                        .disabled(model.busy)
                        .keyboardShortcut("r", modifiers: .command)
                }
                if model.busy { ProgressView(value: model.progress) }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selection {
                        case "Overview": overview
                        case "Findings": findings
                        case "Evidence": evidence
                        case "Actions": actions
                        default: reports
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                }
            }.padding(28)
        }
        .alert("TuneUp", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .alert("Enable the application firewall?", isPresented: $confirmFirewall) {
            Button("Cancel", role: .cancel) {}
            Button("Enable firewall") { model.enableFirewall() }
        } message: { Text("macOS will request administrator authorization. This enables the firewall without enabling ‘Block all incoming connections’. Some apps may ask to accept incoming connections. You can reverse this in Security & Privacy → Firewall.") }
        .alert("Verify the startup filesystem?", isPresented: $confirmDisk) {
            Button("Cancel", role: .cancel) {}
            Button("Verify") { model.verifyDisk(); selection = "Evidence" }
        } message: { Text("This requests verification, not repair or deletion. The Mac may briefly pause. Save your work first. The check is limited to five minutes; Recovery Disk Utility may be needed for a complete check.") }
    }

    private var overview: some View {
        Group {
            card("A thorough baseline, without blind cleanup", "Checks cover CPU samples, memory pressure, battery, SSD, storage, encryption, firewall, SIP, Gatekeeper, enrollment, updates, startup files, crash summaries and network configuration. Findings point to evidence; no health score hides uncertainty.")
            Toggle("Check Apple updates and internet connectivity", isOn: $model.online).disabled(model.busy)
            Text("Online checks contact Apple's update service and example.com. They don't install updates. Offline scans still inspect local configuration. A scan typically takes 1–5 minutes.")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 16) {
                metric("Attention", model.report.findings.filter { $0.severity == .attention }.count, .orange)
                metric("Needs review", model.report.findings.filter { $0.severity == .review }.count, .blue)
                metric("Unverified", model.report.findings.filter { $0.severity == .unknown }.count, .gray)
            }
            card("Boundaries that matter", "This app cannot certify the absence of malware, verify browser support from a version string, repair worn hardware, or make an unsupported OS secure. It never clears caches, deletes personal files, removes snapshots, disables security protections, or installs unofficial OS patches.")
            if !model.report.observations.isEmpty {
                Text("\(model.report.observations.count) observations collected. \(model.report.completed ? "Scan finished." : "Scan incomplete or still running.")")
                Button("Review findings") { selection = "Findings" }
            }
        }
    }

    private var findings: some View {
        Group {
            if model.report.observations.isEmpty { Text("Run a scan to collect evidence first.") }
            ForEach(model.report.findings) { finding in
                VStack(alignment: .leading, spacing: 8) {
                    Label(finding.severity.rawValue.uppercased(), systemImage: finding.severity == .attention ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption.bold()).foregroundColor(color(finding.severity))
                    Text(finding.title).font(.headline)
                    Text(finding.detail).foregroundColor(.secondary).textSelection(.enabled)
                    if let action = finding.action {
                        Button("Open relevant settings / location") { open(action) }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor)).cornerRadius(12)
            }
        }
    }

    private var evidence: some View {
        Group {
            TextField("Filter checks by title, category or output", text: $search)
            Text("Raw evidence stays on this Mac unless you export it. Failed checks are not passes. Startup entries and crash reports require interpretation.")
                .font(.caption).foregroundColor(.secondary)
            ForEach(model.report.observations.filter { search.isEmpty || ($0.title + $0.category + $0.output).localizedCaseInsensitiveContains(search) }) { item in
                DisclosureGroup {
                    Text(item.output.isEmpty ? "(No output)" : item.output)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(item.category) · \(item.title)").font(.headline)
                        Text("\(item.succeeded ? "Collected" : "Not verified") · exit \(item.exitCode)\(item.timedOut ? " · timed out" : "") · \(item.date.formatted())")
                            .font(.caption).foregroundColor(item.succeeded ? .secondary : .orange)
                    }
                }.padding(12).background(Color(NSColor.controlBackgroundColor)).cornerRadius(10)
            }
        }
    }

    private var actions: some View {
        Group {
            card("Repair from evidence", "Use supported settings and vendor uninstallers. No mass uninstall or blind ‘optimization’ is performed. After changing something, run a fresh scan and compare reports.")
            actionRow("Enable firewall", "Requests macOS administrator authorization and checks the result. Reversible in Security & Privacy.", "Enable…") { confirmFirewall = true }
            actionRow("Verify filesystem", "Checks the startup volume without requesting repairs. Review the command result in Evidence.", "Verify…") { confirmDisk = true }
            actionRow("Apple updates", "Review available updates and restart requirements in Software Update.", "Open") { open("updates") }
            actionRow("Application updates", "Use App Store updates plus each vendor's updater. Browser and Office updates may require a newer OS.", "App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
            actionRow("Remove unused applications", "Use a vendor uninstaller for VPNs. For ordinary apps, review Applications in Finder. Keep documents and OneDrive files.", "Applications") { open("applications") }
            actionRow("Startup software", "Review login items. A launch file's presence does not prove the software is running.", "Open") { open("login") }
            actionRow("Wi-Fi and DNS", "Inspect TCP/IP, DNS and proxies. Renew DHCP from Advanced → TCP/IP. Do not delete network preference files blindly.", "Network") { open("network") }
            actionRow("Encryption and security", "Review FileVault recovery-key handling, firewall and app permissions.", "Security") { open("security") }
            actionRow("Disk Utility", "Use First Aid when verification indicates a problem. Repairing the startup disk may require macOS Recovery.", "Open") { open("disk") }
            actionRow("Backups", "Optional review of Time Machine. An inaccessible destination does not establish when the last successful backup occurred.", "Open") { open("backup") }
        }
    }

    private var reports: some View {
        Group {
            card("One report instead of repeated commands", "Export a Markdown report to share for interpretation. The default contains findings and command status. Enable evidence to include automatically redacted diagnostic output. Review every export before sharing: redaction cannot remove every identifier.")
            Toggle("Include redacted diagnostic evidence in shared report", isOn: $model.includeEvidence)
            Button("Export shareable Markdown…") { model.export() }.disabled(model.report.observations.isEmpty)
            Divider()
            Text("Before / after comparison").font(.title2.bold())
            Text("Save a private baseline before repairs. After restarting and running a new scan, compare with it. Private JSON contains unredacted evidence; do not share it casually.")
            HStack {
                Button("Save private baseline…") { model.saveBaseline() }
                Button("Compare with baseline…") { model.compare() }
            }.disabled(model.report.observations.isEmpty || model.busy)
            if let comparison = model.comparison { Text(comparison).textSelection(.enabled) }
        }
    }

    private func actionRow(_ title: String, _ detail: String, _ button: String, perform: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.callout).foregroundColor(.secondary) }
            Spacer(); Button(button, action: perform).disabled(model.busy)
        }.padding(14).background(Color(NSColor.controlBackgroundColor)).cornerRadius(10)
    }
    private func card(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.title3.bold()); Text(detail).foregroundColor(.secondary) }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor)).cornerRadius(12)
    }
    private func metric(_ title: String, _ count: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading) { Text("\(count)").font(.largeTitle.bold()).foregroundColor(tint); Text(title).font(.caption) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(tint.opacity(0.08)).cornerRadius(12)
    }
    private func color(_ severity: Severity) -> Color {
        switch severity { case .attention: return .orange; case .review: return .blue; case .info: return .green; case .unknown: return .secondary }
    }
    private func icon(_ page: String) -> String {
        switch page { case "Overview": return "macbook"; case "Findings": return "checklist"; case "Evidence": return "doc.text.magnifyingglass"; case "Actions": return "wrench.and.screwdriver"; default: return "square.and.arrow.up" }
    }
    private func open(_ destination: String) {
        let targets = [
            "updates": "x-apple.systempreferences:com.apple.preferences.softwareupdate",
            "firewall": "x-apple.systempreferences:com.apple.preference.security?Firewall",
            "security": "x-apple.systempreferences:com.apple.preference.security",
            "network": "x-apple.systempreferences:com.apple.preference.network",
            "login": "x-apple.systempreferences:com.apple.preferences.users",
            "storage": "x-apple.systempreferences:com.apple.preference.general?Storage",
            "backup": "x-apple.systempreferences:com.apple.prefs.backup"
        ]
        if destination == "applications" { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
        else if destination == "disk" { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
        else if let target = targets[destination], let url = URL(string: target) { NSWorkspace.shared.open(url) }
    }
}
