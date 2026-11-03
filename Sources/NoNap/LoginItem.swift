import Foundation

/// Opens the app at login through a per-user LaunchAgent.
enum LoginItem {
    private static var label: String { "\(App.bundleID).login" }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        guard
            let data = try? Data(contentsOf: agentURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any],
            let arguments = dictionary["ProgramArguments"] as? [String]
        else {
            return false
        }

        return arguments.contains(Bundle.main.bundlePath)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-gj", Bundle.main.bundlePath],
                "RunAtLoad": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}
