import Foundation

/// Keeps the sandbox grant alive for as long as the archive is in use.
final class ArchiveFolderSelection {
    static let bookmarkKey = "archiveFolderBookmark"
    private let defaults: UserDefaults
    private var accessedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    func restore() throws -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        try activate(url, saveBookmark: stale)
        return url
    }

    func select(_ url: URL) throws {
        try activate(url, saveBookmark: true)
    }

    private func activate(_ url: URL, saveBookmark: Bool) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.path) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            // Verify that the archive can be listed before enabling capture.
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            if saveBookmark {
                let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(bookmark, forKey: Self.bookmarkKey)
            }
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = accessing ? url : nil
    }
}
