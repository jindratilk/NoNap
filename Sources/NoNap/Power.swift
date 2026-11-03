import Foundation
import IOKit

/// Reads and changes the system's `disablesleep` setting.
enum Power {
    enum Failure: LocalizedError {
        case cancelled
        case command(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled."
            case .command(let message): message
            }
        }
    }

    private static let sudoersFile = "/private/etc/sudoers.d/90-nonap"

    /// The value the kernel is using right now. It comes from the registry rather than `pmset -g`,
    /// so it is cheap enough to poll and needs no subprocess. The kernel only publishes the
    /// property once it has been set, so a missing property means sleep was never disabled.
    static func isSleepDisabled() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// Blocks until done, so call it off the main thread. Only these two exact pmset invocations
    /// are authorized. No password is stored.
    static func setSleepDisabled(_ disabled: Bool) throws {
        let arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        do {
            _ = try run("/usr/bin/sudo", arguments)
        } catch Failure.command(let message) where message.contains("a password is required") {
            try installPermission()
            _ = try run("/usr/bin/sudo", arguments)
        }
    }

    /// Asks for the administrator password once, to allow the two pmset commands without one.
    private static func installPermission() throws {
        let username = NSUserName()
        guard username.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil else {
            throw Failure.command("This account name cannot be used for automatic setup.")
        }
        let policy = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        // Generate the policy inside the privileged shell, validate it before installing,
        // and use a root-owned temporary file ignored by sudo's includedir handling.
        let command = """
        set -eu
        destination=\(sudoersFile)
        if [ -e "$destination" ]; then
            /usr/bin/printf '%s\\n' \(shellQuote(policy)) | /usr/bin/cmp -s - "$destination" || {
                /usr/bin/printf '%s\\n' 'A different NoNap permission file already exists.' >&2
                exit 1
            }
            /usr/sbin/visudo -c
            exit 0
        fi
        temporary=$(/usr/bin/mktemp /private/etc/sudoers.d/.nonap-XXXXXX)
        trap '/bin/rm -f "$temporary"' EXIT
        /usr/bin/printf '%s\\n' \(shellQuote(policy)) > "$temporary"
        /usr/sbin/chown root:wheel "$temporary"
        /bin/chmod 0440 "$temporary"
        /usr/sbin/visudo -cf "$temporary"
        /bin/mv "$temporary" "$destination"
        if ! /usr/sbin/visudo -c; then
            /bin/rm -f "$destination"
            exit 1
        fi
        """
        let prompt = "\(App.name) needs your password once to switch lid sleep. It won't ask again."
        let script = "do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote(prompt))"
        do {
            _ = try run("/usr/bin/osascript", ["-e", script])
        } catch Failure.command(let message) where message.contains("(-128)") {
            throw Failure.cancelled
        }
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.command(message.isEmpty ? "\(executable) failed." : message)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

/// The running bundle's identity, so the same code works whatever the bundle is called.
enum App {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "NoNap" }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app.nonap.NoNap" }
    static var executable: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "NoNap" }
}
