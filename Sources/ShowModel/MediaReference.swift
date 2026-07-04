import Foundation

/// Reference to a media file on disk. Resolution order: relative-to-showfile
/// path → plain (non-security-scoped) bookmark → absolute path. All three are
/// kept in sync on save so shows survive folder moves and drive renames.
public struct MediaReference: Codable, Hashable, Sendable {
    /// Primary reference, relative to the show file's folder ("../Media/a.wav").
    public var relativePath: String?
    /// Plain bookmark — survives same-volume moves/renames of the media file.
    public var bookmark: Data?
    /// Last resort + relink hint (filename matching).
    public var absolutePath: String

    public init(relativePath: String? = nil, bookmark: Data? = nil, absolutePath: String) {
        self.relativePath = relativePath
        self.bookmark = bookmark
        self.absolutePath = absolutePath
    }

    public init(fileURL: URL, showFolder: URL?) {
        self.absolutePath = fileURL.path
        self.bookmark = try? fileURL.bookmarkData()
        if let showFolder {
            self.relativePath = Self.relativePath(of: fileURL, from: showFolder)
        }
    }

    public var fileName: String {
        (absolutePath as NSString).lastPathComponent
    }

    /// Resolve to an existing file, or nil → cue is "broken media" and needs relink.
    public func resolve(showFolder: URL?) -> URL? {
        let fm = FileManager.default
        if let relativePath, let showFolder {
            // appendingPathComponent + standardize (rather than relativeTo:) so
            // resolution doesn't depend on the base URL's directory flag.
            let url = showFolder.appendingPathComponent(relativePath).standardizedFileURL
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return url
            }
        }
        if fm.fileExists(atPath: absolutePath) {
            return URL(fileURLWithPath: absolutePath)
        }
        return nil
    }

    /// Re-anchor all three references to a (possibly new) show folder.
    /// Called for every media cue on Save and Save-As.
    public mutating func rebase(resolvedURL: URL, showFolder: URL?) {
        absolutePath = resolvedURL.path
        bookmark = try? resolvedURL.bookmarkData()
        relativePath = showFolder.flatMap { Self.relativePath(of: resolvedURL, from: $0) }
    }

    static func relativePath(of file: URL, from folder: URL) -> String? {
        let fileComponents = file.standardizedFileURL.pathComponents
        let folderComponents = folder.standardizedFileURL.pathComponents
        guard fileComponents.first == folderComponents.first else { return nil }

        var common = 0
        while common < min(fileComponents.count - 1, folderComponents.count),
              fileComponents[common] == folderComponents[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: folderComponents.count - common)
        let downs = fileComponents[common...]
        return (ups + downs).joined(separator: "/")
    }
}
