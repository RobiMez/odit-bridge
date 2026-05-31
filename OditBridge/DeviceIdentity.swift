import Foundation

// Persistence layer for the device's clientId UUID. We mirror to THREE places
// so it's extremely hard to lose:
//
//   1. Keychain (survives uninstall + ~/Library/Preferences deletion)
//   2. A flat file at ~/Library/Application Support/com.robi.OditBridge/
//      device-id.txt (human-readable; user can back it up or copy by hand)
//   3. UserDefaults (legacy mirror for older installs + fastest read)
//
// On read we prefer the most durable layer present and back-fill the others.
// On write we update all three. We also check the LEGACY locations under
// `com.ayautomate.OditBridge` (the bundle's previous id) so anyone upgrading
// from that build keeps their existing UUID without re-linking.
enum DeviceIdentity {
    static let defaultsKey = "odit.clientId"
    static let currentService = "com.robi.OditBridge"
    static let currentSupportDir = "com.robi.OditBridge"

    private static let legacyServices = ["com.ayautomate.OditBridge"]
    private static let legacySupportDirs = ["com.ayautomate.OditBridge"]
    private static let legacyDefaultsBundles = ["com.ayautomate.OditBridge"]

    static func read() -> String? {
        // 1) Current locations
        if let v = Keychain.get(defaultsKey, service: currentService), !v.isEmpty {
            backfillIfNeeded(value: v)
            return v
        }
        if let v = readFile(supportDir: currentSupportDir), !v.isEmpty {
            backfillIfNeeded(value: v)
            return v
        }
        if let v = UserDefaults.standard.string(forKey: defaultsKey), !v.isEmpty {
            backfillIfNeeded(value: v)
            return v
        }

        // 2) Legacy locations (one-time migration on first launch after rename)
        for service in legacyServices {
            if let v = Keychain.get(defaultsKey, service: service), !v.isEmpty {
                write(v)
                return v
            }
        }
        for dir in legacySupportDirs {
            if let v = readFile(supportDir: dir), !v.isEmpty {
                write(v)
                return v
            }
        }
        for bundleId in legacyDefaultsBundles {
            if let v = readLegacyDefaults(bundleId: bundleId), !v.isEmpty {
                write(v)
                return v
            }
        }
        return nil
    }

    static func write(_ value: String) {
        Keychain.set(defaultsKey, value, service: currentService)
        writeFile(value, supportDir: currentSupportDir)
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    static var humanReadablePath: String {
        fileURL(supportDir: currentSupportDir)?.path
            ?? "~/Library/Application Support/\(currentSupportDir)/device-id.txt"
    }

    // MARK: helpers

    private static func fileURL(supportDir: String) -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(supportDir, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("device-id.txt")
    }

    private static func readFile(supportDir: String) -> String? {
        guard let url = fileURL(supportDir: supportDir) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeFile(_ value: String, supportDir: String) {
        guard let url = fileURL(supportDir: supportDir) else { return }
        try? value.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    private static func readLegacyDefaults(bundleId: String) -> String? {
        // Read the legacy bundle's preferences plist directly. Unsandboxed apps
        // can stat sibling preferences files without an entitlement.
        let path = NSHomeDirectory() + "/Library/Preferences/\(bundleId).plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist[defaultsKey] as? String
    }

    private static func backfillIfNeeded(value: String) {
        if Keychain.get(defaultsKey, service: currentService) != value {
            Keychain.set(defaultsKey, value, service: currentService)
        }
        if readFile(supportDir: currentSupportDir) != value {
            writeFile(value, supportDir: currentSupportDir)
        }
        if UserDefaults.standard.string(forKey: defaultsKey) != value {
            UserDefaults.standard.set(value, forKey: defaultsKey)
        }
    }
}
