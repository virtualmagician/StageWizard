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
    /// Fired after undo/redo restored the document — a MUCH lighter touch
    /// than onDocumentReplaced (playback keeps running; only the playhead
    /// gets revalidated).
    @ObservationIgnored var onUndoRestore: (@MainActor () -> Void)?
    /// Fired whenever the recents list gained an entry (open/save).
    @ObservationIgnored var onRecentsChanged: (@MainActor () -> Void)?

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

    // MARK: - Undo / redo (snapshot-based — shows are small value types)

    private struct UndoEntry {
        var show: ShowFile
        var selection: Set<UUID>
        var timestamp: ContinuousClock.Instant
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    /// undoStack depth at the last save; nil = the saved state fell off the
    /// capped stack and can no longer be reached by undoing.
    private var savePointDepth: Int? = 0
    /// True while save-time bookkeeping (media rebase) writes the model —
    /// those are not user edits and must not create undo steps.
    private var undoRecordingSuspended = false
    private static let undoCoalesceWindow: Duration = .milliseconds(500)
    private static let undoCap = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(currentEntry())
        restore(entry)
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(currentEntry())
        restore(entry)
    }

    private func currentEntry() -> UndoEntry {
        // Backdated so a restored state never coalesces with the next edit.
        UndoEntry(show: show, selection: selection,
                  timestamp: ContinuousClock.now - .seconds(60))
    }

    private func restore(_ entry: UndoEntry) {
        // Workspace mode is live state driven directly by AppModel.setMode,
        // not something undo/redo should ever flip out from under it — carry
        // the current (live) mode forward across the restore.
        let liveMode = show.settings.workspaceMode
        show = entry.show
        show.settings.workspaceMode = liveMode
        selection = entry.selection.filter { show.cue(withID: $0) != nil }
        isDirty = savePointDepth != undoStack.count
        onUndoRestore?()
    }

    private func recordUndoSnapshot() {
        guard !undoRecordingSuspended else { return }
        let now = ContinuousClock.now
        if let last = undoStack.last, now - last.timestamp < Self.undoCoalesceWindow {
            // A burst (drag ticks, typing) collapses into one step: keep the
            // pre-burst snapshot, refresh the clock so the burst continues.
            undoStack[undoStack.count - 1].timestamp = now
        } else {
            undoStack.append(UndoEntry(show: show, selection: selection, timestamp: now))
            if undoStack.count > Self.undoCap {
                undoStack.removeFirst()
                savePointDepth = savePointDepth.flatMap { $0 > 0 ? $0 - 1 : nil }
            }
        }
        redoStack.removeAll()
    }

    private func resetUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        savePointDepth = 0
    }

    /// Save-time undo bookkeeping — called by `write(to:)` on a successful
    /// save. Not `private`: it's the whole seam under test for the
    /// coalescing-vs-savePointDepth fix, exercised directly (via
    /// `@testable import`) so tests don't need to drive NSSavePanel/disk I/O.
    ///
    /// Anchors the save point at the current undo depth, then breaks
    /// coalescing on the entry now anchoring it: without this, an edit
    /// landing inside the coalesce window right after a save folds into that
    /// entry, so undoStack.count stays == savePointDepth despite the unsaved
    /// edit — a later redo would then report isDirty == false with real
    /// unsaved changes on screen. Backdating (same trick as currentEntry(),
    /// used by undo/redo) forces the next mutate to append a fresh entry
    /// instead of coalescing into this one.
    func markSaved() {
        isDirty = false
        savePointDepth = undoStack.count
        if !undoStack.isEmpty {
            undoStack[undoStack.count - 1].timestamp = ContinuousClock.now - .seconds(60)
        }
    }

    /// Current undo-stack depth — not `private` only so tests can assert on
    /// it directly around `markSaved()`; production logic only needs
    /// `canUndo`.
    var undoDepthForTesting: Int { undoStack.count }

    // MARK: - Mutation

    /// Single funnel for all model mutations so dirty tracking can't be missed.
    func mutate(_ change: (inout ShowFile) -> Void) {
        recordUndoSnapshot()
        change(&show)
        isDirty = true
    }

    /// Mutate without recording an undo step — for persisted state that
    /// mirrors something already tracked live outside the undo stack (e.g.
    /// workspace mode, which AppModel.setMode drives directly). Still marks
    /// the document dirty: this is real persisted state, just not something
    /// undo/redo should ever flip on its own.
    func mutateWithoutUndo(_ change: (inout ShowFile) -> Void) {
        undoRecordingSuspended = true
        defer { undoRecordingSuspended = false }
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
        resetUndoHistory()
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
            resetUndoHistory()
            fileURL = url
            selection = []
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            UserDefaults.standard.set(url.path, forKey: Self.lastShowPathKey)
            onRecentsChanged?()
            onDocumentReplaced?()
        } catch {
            presentError("Couldn't open \(url.lastPathComponent)", error)
        }
    }

    /// Most recent successfully opened/saved show — restored at launch.
    /// (NSDocumentController's recents list loads asynchronously and can be
    /// empty during applicationDidFinishLaunching, so we keep our own copy.)
    static let lastShowPathKey = "lastShowPath"

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
        // Save-time bookkeeping is not a user edit.
        undoRecordingSuspended = true
        rebaseMediaReferences(newShowFolder: url.deletingLastPathComponent())
        undoRecordingSuspended = false
        do {
            let data = try show.encoded()
            backupExistingFile(at: url)
            try data.write(to: url, options: .atomic)
            fileURL = url
            markSaved()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            UserDefaults.standard.set(url.path, forKey: Self.lastShowPathKey)
            onRecentsChanged?()
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
            case .image(var body):
                if let resolved = body.media.resolve(showFolder: oldFolder) {
                    body.media.rebase(resolvedURL: resolved, showFolder: newShowFolder)
                    show.cues[index].body = .image(body)
                }
            case .camera(var body):
                if var emitter = body.effects.dustEmitter,
                   let resolved = emitter.resolve(showFolder: oldFolder) {
                    emitter.rebase(resolvedURL: resolved, showFolder: newShowFolder)
                    body.effects.dustEmitter = emitter
                    show.cues[index].body = .camera(body)
                }
            case .slide(var body):
                if let resolved = body.media.resolve(showFolder: oldFolder) {
                    body.media.rebase(resolvedURL: resolved, showFolder: newShowFolder)
                }
                if var source = body.sourceDeck, let resolved = source.resolve(showFolder: oldFolder) {
                    source.rebase(resolvedURL: resolved, showFolder: newShowFolder)
                    body.sourceDeck = source
                }
                show.cues[index].body = .slide(body)
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
