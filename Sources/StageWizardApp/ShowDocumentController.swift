import AppKit
import Observation
import UniformTypeIdentifiers

/// Owns the open show document: model, file URL, dirty state, save/open,
/// rotating backups. Deliberately not DocumentGroup/ReferenceFileDocument —
/// we need the file URL at all times for relative media resolution, and
/// autosave must pause during playback.
@MainActor
@Observable
final class ShowDocumentController {
    static let showUTType = UTType(exportedAs: "com.marcotempest.stagewizard.show", conformingTo: .json)
    static let backupsToKeep = 10

    private(set) var show = ShowFile()
    private(set) var fileURL: URL?
    private(set) var isDirty = false

    var selection: Set<UUID> = []

    /// Set by the runtime while cues are active; blocks autosave disk I/O mid-show.
    var isPlaybackActive = false

    /// Fired after new/open replaced the document — the transport must reset
    /// (stop stale playback, clear the old show's playhead).
    @ObservationIgnored var onDocumentReplaced: (@MainActor () -> Void)?

    private var autosaveTimer: Timer?

    init() {
        // Autosave: only when dirty, titled to a real file, and nothing is playing.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isDirty, self.fileURL != nil, !self.isPlaybackActive else { return }
                self.save()
            }
        }
    }

    var showFolder: URL? {
        fileURL?.deletingLastPathComponent()
    }

    var windowTitle: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled Show"
        return isDirty ? "\(name) — Edited" : name
    }

    // MARK: - Mutation

    /// Single funnel for all model mutations so dirty tracking can't be missed.
    func mutate(_ change: (inout ShowFile) -> Void) {
        change(&show)
        isDirty = true
    }

    func cue(withID id: UUID) -> Cue? {
        show.cue(withID: id)
    }

    func updateCue(_ id: UUID, _ change: (inout Cue) -> Void) {
        guard let index = show.indexOfCue(withID: id) else { return }
        mutate { change(&$0.cues[index]) }
    }

    // MARK: - File operations

    func newDocument() {
        guard confirmDiscardIfDirty(action: "creating a new show") else { return }
        show = ShowFile()
        fileURL = nil
        selection = []
        isDirty = false
        onDocumentReplaced?()
    }

    func openDocument() {
        guard confirmDiscardIfDirty(action: "opening another show") else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.showUTType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            show = try ShowFile.load(from: data)
            fileURL = url
            selection = []
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            onDocumentReplaced?()
        } catch {
            presentError("Couldn't open \(url.lastPathComponent)", error)
        }
    }

    /// Quit-time gate: returns true when it's safe to terminate.
    func confirmQuit() -> Bool {
        confirmDiscardIfDirty(action: "quitting")
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.showUTType]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled Show.stagewizard"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        rebaseMediaReferences(newShowFolder: url.deletingLastPathComponent())
        do {
            let data = try show.encoded()
            backupExistingFile(at: url)
            try data.write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            presentError("Couldn't save show", error)
            return false
        }
    }

    /// Re-anchor every resolvable media reference to the (possibly new) show folder.
    private func rebaseMediaReferences(newShowFolder: URL) {
        let oldFolder = showFolder
        for index in show.cues.indices {
            switch show.cues[index].body {
            case .audio(var body):
                if let resolved = body.media.resolve(showFolder: oldFolder) {
                    body.media.rebase(resolvedURL: resolved, showFolder: newShowFolder)
                    show.cues[index].body = .audio(body)
                }
            case .video(var body):
                if let resolved = body.media.resolve(showFolder: oldFolder) {
                    body.media.rebase(resolvedURL: resolved, showFolder: newShowFolder)
                    show.cues[index].body = .video(body)
                }
            default:
                break
            }
        }
    }

    /// Copy the current on-disk file into a rotating backups folder before overwrite.
    private func backupExistingFile(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backupsDir = url.deletingLastPathComponent()
            .appendingPathComponent(".stagewizard-backups", isDirectory: true)
        do {
            try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let stamp = formatter.string(from: Date())
            let base = url.deletingPathExtension().lastPathComponent
            let backupURL = backupsDir.appendingPathComponent("\(base)-\(stamp).stagewizard")
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
            pruneBackups(in: backupsDir, base: base)
        } catch {
            // Backups are best-effort; never block a save on them.
        }
    }

    private func pruneBackups(in dir: URL, base: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("\(base)-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in backups.dropFirst(Self.backupsToKeep) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - Alerts

    /// Returns true if it's safe to proceed (saved, discarded, or wasn't dirty).
    private func confirmDiscardIfDirty(action: String) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before \(action)?"
        alert.informativeText = "Unsaved changes to \(windowTitle) will be lost otherwise."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
