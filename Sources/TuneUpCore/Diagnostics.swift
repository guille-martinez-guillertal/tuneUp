import Foundation

public enum Severity: String, Codable, CaseIterable {
    case attention, review, info, unknown
}

public struct Finding: Identifiable, Codable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var action: String?
    public init(_ id: String, _ severity: Severity, _ title: String, _ detail: String, action: String? = nil) {
        self.id = id; self.severity = severity; self.title = title; self.detail = detail; self.action = action
    }
}

public struct Probe: Identifiable {
    public let id: String
    public let category: String
    public let title: String
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval
    public init(_ id: String, _ category: String, _ title: String, _ executable: String, _ arguments: [String], timeout: TimeInterval = 25) {
        self.id = id; self.category = category; self.title = title
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
    }
}

public struct Observation: Identifiable, Codable {
    public var id: String
    public var category: String
    public var title: String
    public var output: String
    public var exitCode: Int32
    public var timedOut: Bool
    public var date: Date
    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public init(id: String, category: String = "Test", title: String = "Test", output: String, exitCode: Int32 = 0, timedOut: Bool = false, date: Date = Date()) {
        self.id = id; self.category = category; self.title = title; self.output = output
        self.exitCode = exitCode; self.timedOut = timedOut; self.date = date
    }
}

public struct Report: Codable {
    public var schemaVersion = 1
    public var generatedAt = Date()
    public var completed = false
    public var observations: [Observation] = []
    public var findings: [Finding] { Analyzer.findings(observations) }
    public init() {}
    public func markdown(includeEvidence: Bool) -> String {
        var lines = ["# TuneUp report", "", "Generated: \(generatedAt)", "Scan complete: \(completed)",
                     "This is a diagnostic snapshot, not a malware clearance or security certification.", "", "## Findings"]
        for finding in findings {
            lines += ["", "### [\(finding.severity.rawValue)] \(finding.title)", finding.detail]
        }
        lines += ["", "## Checks"]
        for item in observations {
            lines += ["", "### \(item.category): \(item.title)", "Exit: \(item.exitCode); timed out: \(item.timedOut)"]
            if includeEvidence { lines += ["```text", Redactor.scrub(item.output).replacingOccurrences(of: "```", with: "'''"), "```"] }
        }
        return lines.joined(separator: "\n")
    }
}

// Fixed executables and arguments only: diagnostic output never becomes shell code.
public enum Runner {
    public static func run(_ probe: Probe) -> Observation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probe.executable)
        process.arguments = probe.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["LANG"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // A temporary output file avoids pipe-buffer deadlocks on large system reports.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else {
            return Observation(id: probe.id, category: probe.category, title: probe.title, output: "Could not create diagnostic output file.", exitCode: -1)
        }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }
        process.standardOutput = handle; process.standardError = handle
        do { try process.run() } catch {
            return Observation(id: probe.id, category: probe.category, title: probe.title, output: error.localizedDescription, exitCode: -1)
        }
        let deadline = Date().addingTimeInterval(probe.timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                #if canImport(Darwin)
                Darwin.kill(process.processIdentifier, SIGKILL)
                #else
                Glibc.kill(process.processIdentifier, SIGKILL)
                #endif
            }
        }
        process.waitUntilExit()
        let reader = try? FileHandle(forReadingFrom: url)
        let data = (try? reader?.read(upToCount: 512_000)) ?? Data()
        try? reader?.close()
        let output = String(decoding: data, as: UTF8.self)
        return Observation(id: probe.id, category: probe.category, title: probe.title,
                           output: output + (output.utf8.count >= 512_000 ? "\n[Output truncated]" : ""),
                           exitCode: process.terminationStatus, timedOut: timedOut)
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum Catalog {
    public static func probes(online: Bool) -> [Probe] {
        var items: [Probe] = [
            Probe("os", "Overview", "macOS version", "/usr/bin/sw_vers", []),
            Probe("hardware", "Hardware", "Hardware overview", "/usr/sbin/system_profiler", ["SPHardwareDataType"], timeout: 45),
            Probe("battery", "Hardware", "Battery and power", "/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 45),
            Probe("disk", "Storage", "Physical SSD health", "/usr/sbin/diskutil", ["info", "disk0"]),
            Probe("space", "Storage", "Available storage", "/bin/df", ["-Pk", "/System/Volumes/Data"]),
            Probe("apfs", "Storage", "APFS containers", "/usr/sbin/diskutil", ["apfs", "list"]),
            Probe("snapshots", "Storage", "Local Time Machine snapshots", "/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
            Probe("cpu", "Performance", "CPU samples (three, five seconds apart)", "/usr/bin/top", ["-l", "3", "-s", "5", "-n", "15", "-o", "cpu", "-stats", "pid,command,cpu,mem,threads,state"]),
            Probe("memory", "Performance", "Memory pressure", "/usr/bin/memory_pressure", []),
            Probe("swap", "Performance", "Swap usage", "/usr/sbin/sysctl", ["vm.swapusage"]),
            Probe("thermal", "Performance", "Thermal restrictions", "/usr/bin/pmset", ["-g", "therm"]),
            Probe("power", "Performance", "Power assertions", "/usr/bin/pmset", ["-g", "assertions"]),
            Probe("firewall", "Security", "Application firewall", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
            Probe("filevault", "Security", "FileVault", "/usr/bin/fdesetup", ["status"]),
            Probe("sip", "Security", "System Integrity Protection", "/usr/bin/csrutil", ["status"]),
            Probe("gatekeeper", "Security", "Gatekeeper assessments", "/usr/sbin/spctl", ["--status"]),
            Probe("enrollment", "Security", "Organization enrollment", "/usr/bin/profiles", ["status", "-type", "enrollment"]),
            Probe("extensions", "Security", "System extensions", "/usr/bin/systemextensionsctl", ["list"]),
            Probe("xprotect", "Security", "Apple protection package receipts", "/usr/sbin/pkgutil", ["--pkgs=.*(XProtect|MRT).*" ]),
            Probe("interfaces", "Network", "Network interfaces", "/usr/sbin/networksetup", ["-listallhardwareports"]),
            Probe("reachability", "Network", "Network state", "/usr/sbin/scutil", ["--nwi"]),
            Probe("dns", "Network", "DNS configuration", "/usr/sbin/scutil", ["--dns"]),
            Probe("proxy", "Network", "Proxy configuration", "/usr/sbin/scutil", ["--proxy"]),
            Probe("vpn", "Network", "VPN services", "/usr/sbin/scutil", ["--nc", "list"]),
            Probe("route", "Network", "Default IPv4 route", "/sbin/route", ["-n", "get", "default"]),
            Probe("backup", "Backup", "Latest accessible backup", "/usr/bin/tmutil", ["latestbackup"]),
            Probe("developer", "Applications", "Selected developer tools", "/usr/bin/xcode-select", ["-p"])
        ]
        if online {
            items += [
                Probe("updates", "Updates", "Available Apple updates (does not install)", "/usr/sbin/softwareupdate", ["--list"], timeout: 180),
                Probe("https", "Network", "HTTPS connectivity to example.com", "/usr/bin/curl", ["--head", "--connect-timeout", "8", "--max-time", "15", "https://example.com"], timeout: 20),
                Probe("lookup", "Network", "DNS lookup of example.com", "/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "example.com"])
            ]
        }
        return items
    }

    public static func localInventory() -> [Observation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var startup: [String] = []
        var startupErrors = false
        var crashErrors = false
        for path in [home.appendingPathComponent("Library/LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            do {
                let names = try fm.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".plist") }.sorted()
                startup.append("\n\(path):")
                for name in names {
                    let file = URL(fileURLWithPath: path).appendingPathComponent(name)
                    var line = name
                    if let data = try? Data(contentsOf: file),
                       let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                        let args = plist["ProgramArguments"] as? [String] ?? []
                        let program = plist["Program"] as? String ?? args.first ?? "(unspecified)"
                        line += " | executable: \(program) | KeepAlive: \(plist["KeepAlive"] ?? false)"
                    }
                    startup.append(line)
                }
            } catch {
                if fm.fileExists(atPath: path) { startupErrors = true }
                startup.append("\(path): unavailable (\(error.localizedDescription))")
            }
        }
        var apps: [String] = []
        for folder in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "app" {
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: infoURL),
                   let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                    apps.append("\(url.lastPathComponent) | version: \(info["CFBundleShortVersionString"] ?? "unknown") | minimum macOS: \(info["LSMinimumSystemVersion"] ?? "unspecified") | \(url.path)")
                } else { apps.append("\(url.lastPathComponent) | unreadable metadata") }
            }
        }
        var crashes: [String] = []
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for folder in [home.appendingPathComponent("Library/Logs/DiagnosticReports"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")] {
            do {
                let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
                for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    guard modified >= cutoff else { continue }
                    if url.pathExtension == "ips" {
                        var summary = url.lastPathComponent
                        // Parse metadata and termination only; never collect the full memory/thread dump.
                        if let handle = try? FileHandle(forReadingFrom: url) {
                            let bytes = (try? handle.read(upToCount: 128_000)) ?? Data()
                            try? handle.close()
                            if let text = String(data: bytes, encoding: .utf8), let newline = text.firstIndex(of: "\n") {
                                let body = String(text[text.index(after: newline)...])
                                if let data = body.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                                    for key in ["procPath", "parentProc", "exception", "termination"] {
                                        if let value = json[key] { summary += "\n  \(key): \(value)" }
                                    }
                                }
                            }
                        }
                        crashes.append(summary)
                    } else if url.pathExtension == "shutdownStall" { crashes.append(url.lastPathComponent) }
                }
            } catch {
                if fm.fileExists(atPath: folder.path) { crashErrors = true }
                crashes.append("Unable to read \(folder.path): \(error.localizedDescription)")
            }
        }
        return [
            Observation(id: "startup", category: "Startup", title: "Third-party startup inventory", output: startup.joined(separator: "\n"), exitCode: startupErrors ? 1 : 0),
            Observation(id: "apps", category: "Applications", title: "Applications and declared compatibility", output: apps.joined(separator: "\n")),
            Observation(id: "crashes", category: "Reliability", title: "Crash summaries from the last seven days", output: crashes.isEmpty ? "No accessible recent crash reports found." : crashes.joined(separator: "\n"), exitCode: crashErrors ? 1 : 0)
        ]
    }
}
