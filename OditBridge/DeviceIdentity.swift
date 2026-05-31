import Foundation

// Persistence layer for the device's clientId UUID. We mirror to THREE places
// so it's extremely hard to lose:
//
//   1. Keychain (survives uninstall + ~/Library/Preferences deletion)
//   2. A flat file at ~/Library/Application Support/com.ayautomate.OditBridge/
//      device-id.txt (human-readable; user can back it up or copy by hand)
//   3. UserDefaults (legacy mirror for older builds + fastest read)
//
// On read we prefer the most durable layer present and back-fill the others.
// On write we update all three.
enum DeviceIdentity {
    static let defaultsKey = "odit.clientId"

    static func read() -> String? {
        if let v = Keychain.get(defaultsKey), !v.isEmpty {
            backfillIfNeeded(value: v)
            return v
        }
        if let v = readFile(), !v.isEmpty {
            backfillIfNeeded(value: v)
            return v
        }
        if let v = UserDefaults.standard.string(forKey: defaultsKey), !v.isEmpty {
            backfillIfNeeded(value: v)
            return v
        }
        return nil
    }

    static func write(_ value: String) {
        Keychain.set(defaultsKey, value)
        writeFile(value)
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    // MARK: file location

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("com.ayautomate.OditBridge", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("device-id.txt")
    }

    static var humanReadablePath: String {
        fileURL?.path ?? "~/Library/Application Support/com.ayautomate.OditBridge/device-id.txt"
    }

    // MARK: helpers

    private static func readFile() -> String? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeFile(_ value: String) {
        guard let url = fileURL else { return }
        try? value.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    private static func backfillIfNeeded(value: String) {
        if Keychain.get(defaultsKey) != value { Keychain.set(defaultsKey, value) }
        if readFile() != value { writeFile(value) }
        if UserDefaults.standard.string(forKey: defaultsKey) != value {
            UserDefaults.standard.set(value, forKey: defaultsKey)
        }
    }
}
