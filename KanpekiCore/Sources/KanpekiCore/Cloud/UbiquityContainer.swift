import Foundation

/// Resolves the app's iCloud Drive container. `url(forUbiquityContainerIdentifier:)`
/// can block on first call, so this runs off the main actor.
public enum UbiquityContainer {
    public static let identifier = "iCloud.com.dchroninger.kanpeki"

    public struct Info: Sendable, Hashable {
        public let containerURL: URL
        /// `<container>/Documents` — what Files shows under the app icon.
        public let documentsURL: URL
    }

    /// nil when iCloud Drive is off or the user is signed out.
    public static func resolve() async -> Info? {
        await Task.detached(priority: .userInitiated) {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else { return nil }
            let docs = root.appending(path: "Documents", directoryHint: .isDirectory)
            // Creating Documents is what makes the folder appear in Files.
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            return Info(containerURL: root, documentsURL: docs)
        }.value
    }

    public static var isSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }
}

public enum DeviceName {
    public static var current: String {
        #if canImport(UIKit)
        return MainActor.assumeIsolated { UIKit.UIDevice.current.name }
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}
#if canImport(UIKit)
import UIKit
#endif
