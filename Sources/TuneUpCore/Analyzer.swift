import Foundation

public enum Analyzer {
    public static func findings(_ observations: [Observation]) -> [Finding] {
        var result: [Finding] = []
        for item in observations {
            guard item.succeeded else {
                result.append(Finding("unknown-\(item.id)", .unknown, "\(item.title): not verified",
                    item.timedOut ? "The check exceeded its time limit. Retry it; no result is assumed." : "The command failed (exit \(item.exitCode)). Inspect its evidence; this is not a passing check."))
                continue
            }
            let output = item.output
            let lower = output.lowercased()
            switch item.id {
            case "os":
                if output.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("ProductVersion:") && $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).hasPrefix("12.") == true }) {
                    result.append(Finding("legacy-os", .attention, "Monterey has an outdated security baseline", "No updates offered does not mean current security coverage. This 2016 model cannot officially upgrade past Monterey. Consider supported replacement hardware or a supported alternative OS; unofficial patching is outside this app.", action: "updates"))
                } else {
                    result.append(Finding("os-review", .review, "Verify macOS security support", "Compare this version with Apple's current security releases. A version number alone does not establish support.", action: "updates"))
                }
            case "firewall":
                result.append(Finding("firewall", lower.contains("disabled") ? .attention : (lower.contains("enabled") ? .info : .unknown),
                    lower.contains("disabled") ? "Firewall is off" : "Firewall status", output.trimmingCharacters(in: .whitespacesAndNewlines), action: "firewall"))
            case "filevault":
                result.append(Finding("filevault", lower.contains("is off") ? .attention : (lower.contains("is on") ? .info : .review), "FileVault encryption", output.trimmingCharacters(in: .whitespacesAndNewlines), action: "security"))
            case "sip", "gatekeeper":
                let enabled = lower.contains("enabled") && !lower.contains("disabled")
                result.append(Finding(item.id, enabled ? .info : .attention, item.title, output.trimmingCharacters(in: .whitespacesAndNewlines)))
            case "disk":
                let lines = output.components(separatedBy: .newlines).filter { $0.contains("SMART Status") }
                if let smart = lines.first {
                    result.append(Finding("smart", smart.contains("Verified") ? .info : .attention, "SSD SMART status", smart + ". SMART is not a full filesystem or hardware test.", action: "disk"))
                } else { result.append(Finding("smart", .unknown, "SMART status unavailable", "This device did not report SMART status. Hardware health is not established.", action: "disk")) }
            case "battery":
                if lower.contains("service recommended") || lower.contains("replace soon") || lower.contains("replace now") {
                    result.append(Finding("battery", .attention, "Battery service indicated", "The battery reports a service or replacement condition. Arrange battery assessment; software cleanup cannot repair it."))
                } else if lower.contains("condition: normal") || lower.contains("condition:              normal") {
                    result.append(Finding("battery", .info, "Battery reports Normal", "Normal status does not measure real runtime or rule out age-related degradation."))
                } else { result.append(Finding("battery", .review, "Review battery details", "Inspect the battery condition, cycle count and full-charge capacity in the evidence.")) }
            case "space":
                if let line = output.split(separator: "\n").last {
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    if fields.count >= 5, let free = Double(fields[3]), let total = Double(fields[1]), total > 0 {
                        let low = free / total < 0.15 || free < 15 * 1024 * 1024
                        result.append(Finding("space", low ? .attention : .info, low ? "Storage is running low" : "Storage has headroom", String(format: "%.1f GiB available (%.0f%%). Review large personal files before deleting anything. APFS volumes share container space.", free / 1048576, free / total * 100), action: "storage"))
                    }
                }
            case "updates":
                if lower.contains("no new software available") {
                    result.append(Finding("updates", .review, "No Apple updates offered", "This applies to this device's update catalog. It does not establish that macOS or installed applications still receive security fixes.", action: "updates"))
                } else if output.contains("Label:") || output.contains("* Label") {
                    result.append(Finding("updates", .attention, "Apple updates available", "Review the offered updates in Software Update. Save your work first; installation can require a restart.", action: "updates"))
                } else { result.append(Finding("updates", .unknown, "Update availability inconclusive", "The output did not contain a recognized update result. Inspect the evidence.", action: "updates")) }
            case "crashes":
                let ips = output.components(separatedBy: .newlines).filter { $0.hasSuffix(".ips") }
                if !ips.isEmpty {
                    result.append(Finding("crashes", .review, "\(ips.count) recent crash reports", "Reports cover seven days, including before repairs. Check paths and termination reasons below. Repeated reports suggest repeated failures, not necessarily continuous background activity."))
                }
                if lower.contains("company portal.app") && lower.contains("symbol") {
                    result.append(Finding("portal", .attention, "Company Portal sign-in component fails to load", "A report references Company Portal and a missing symbol. Check OS compatibility. If the Mac is unenrolled and Company Portal is unused, uninstall Company Portal without deleting Office or OneDrive data.", action: "applications"))
                }
                if lower.contains("libmainthreadchecker") {
                    result.append(Finding("xcode", .review, "Xcode Main Thread Checker crash", "The developer-tool runtime appears in a crash. If Xcode is unused, remove Xcode.app via Finder. Do not remove personal project folders.", action: "applications"))
                }
            case "startup":
                result.append(Finding("startup", .review, "Review third-party background software", "The evidence lists startup files, not proof that each item is active or malicious. Use vendor uninstallers for obsolete VPNs. Preserve updaters for applications you use.", action: "login"))
            case "apps":
                result.append(Finding("apps", .review, "Application patching requires vendor checks", "Version and minimum-OS metadata do not prove support or authenticity. Open each important app's update page, including your browser. Do not install an incompatible release.", action: "applications"))
            case "proxy":
                if lower.contains("enable : 1") {
                    result.append(Finding("proxy", .review, "A network proxy is enabled", "A proxy can be intentional. If internet connectivity fails, review its settings before removing anything.", action: "network"))
                }
            default: break
            }
        }
        return result.sorted {
            let order: [Severity: Int] = [.attention: 0, .unknown: 1, .review: 2, .info: 3]
            return (order[$0.severity] ?? 4) < (order[$1.severity] ?? 4)
        }
    }
}

public enum Redactor {
    public static func scrub(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"/Users/[^/\s\"\\]+"#, "/Users/[USER]"),
            (#"(?i)(Serial Number[^:\n]*:\s*)[^\n]+"#, "$1[REDACTED]"),
            (#"(?i)(Hardware UUID\s*:\s*)[^\n]+"#, "$1[REDACTED]"),
            (#"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b"#, "[MAC ADDRESS]"),
            (#"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, "[IPv4]"),
            (#"(?i)(?<![a-z0-9])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.%]+"#, "[IPv6]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[EMAIL]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}
