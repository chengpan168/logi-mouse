import Foundation

struct SideButtonApplication {
    let bundleIdentifier: String
    let displayName: String

    init(url: URL) throws {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            throw ApplicationError.missingBundleIdentifier
        }
        bundleIdentifier = identifier
        displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    enum ApplicationError: LocalizedError {
        case missingBundleIdentifier

        var errorDescription: String? { "无法读取此应用的 Bundle ID，请选择有效的 .app 应用。" }
    }
}
