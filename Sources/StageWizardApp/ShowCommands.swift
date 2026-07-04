import SwiftUI
import UniformTypeIdentifiers

/// Menu bar. Note: GO/transport actions deliberately have NO key equivalents —
/// plain keys like Space are handled by ShortcutKit's event monitor so they can
/// be suppressed while text editing.
struct ShowCommands: Commands {
    let document: ShowDocumentController
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(app.mode == .show ? "Exit Show Mode" : "Enter Show Mode") {
                app.setMode(app.mode == .show ? .edit : .show)
            }
            .keyboardShortcut("e")
            Button(app.mode == .rehearsal ? "Exit Rehearsal Mode" : "Enter Rehearsal Mode") {
                app.setMode(app.mode == .rehearsal ? .edit : .rehearsal)
            }
            .keyboardShortcut("r")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Show") { document.newDocument() }
                .keyboardShortcut("n")
            Button("Open Show…") { document.openDocument() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { document.save() }
                .keyboardShortcut("s")
            Button("Save As…") { document.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Cues") {
            // Every item here edits the show — all disabled in Show mode.
            Button("Add Audio Cue…") { CueFactory.addMediaCue(kind: .audio, to: document) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Button("Add Video Cue…") { CueFactory.addMediaCue(kind: .video, to: document) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Button("Add Camera Cue") { CueFactory.addControlCue(.camera(CameraBody()), to: document) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Button("Add Fade Cue") { CueFactory.addControlCue(.fade(FadeBody()), to: document) }
                .keyboardShortcut("4", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Button("Add Stop Cue") { CueFactory.addControlCue(.stop(StopBody()), to: document) }
                .keyboardShortcut("5", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Button("Add Group") { CueFactory.addControlCue(.group(GroupBody()), to: document) }
                .keyboardShortcut("6", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Divider()
            Button("Duplicate Selected Cues") { CueFactory.duplicateSelection(in: document) }
                .keyboardShortcut("d")
                .disabled(app.isShowMode)
            Button("Delete Selected Cues") { CueFactory.deleteSelection(in: document) }
                .disabled(app.isShowMode)
        }
    }
}

/// Creation/removal helpers shared by menus, toolbar, and context menus.
@MainActor
enum CueFactory {
    enum MediaKind {
        case audio, video
    }

    static func addMediaCue(kind: MediaKind, to document: ShowDocumentController) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = kind == .audio ? [.audio] : [.movie, .video]
        panel.message = kind == .audio ? "Choose audio files" : "Choose video files"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        for url in panel.urls {
            let media = MediaReference(fileURL: url, showFolder: document.showFolder)
            let body: CueBody = kind == .audio
                ? .audio(AudioBody(media: media))
                : .video(VideoBody(media: media, outputGroupID: defaultOutputGroupID(in: document)))
            insert(Cue(number: document.show.nextCueNumber(), body: body), into: document)
        }
    }

    static func addControlCue(_ body: CueBody, to document: ShowDocumentController) {
        var body = body
        // New camera cues route to the first output group, like video.
        if case .camera(var camera) = body, camera.outputGroupID == nil {
            camera.outputGroupID = defaultOutputGroupID(in: document)
            body = .camera(camera)
        }
        insert(Cue(number: document.show.nextCueNumber(), body: body), into: document)
    }

    /// Outputs are required (no implicit main-display target) — new video and
    /// camera cues default to the first configured group.
    static func defaultOutputGroupID(in document: ShowDocumentController) -> UUID? {
        document.show.settings.outputGroups.first?.id
    }

    /// Insert after the last selected cue (or append), inheriting its parent
    /// group so new cues land next to the selection. Anchoring on a group
    /// header inserts after the whole group block, never between the header
    /// and its children.
    static func insert(_ cue: Cue, into document: ShowDocumentController) {
        var cue = cue
        document.mutate { show in
            let selectedIndexes = document.selection.compactMap { show.indexOfCue(withID: $0) }
            if let anchor = selectedIndexes.max() {
                let anchorCue = show.cues[anchor]
                var insertAt = anchor + 1
                if case .group = anchorCue.body {
                    // Skip the contiguous child block.
                    while insertAt < show.cues.count, show.cues[insertAt].parentID == anchorCue.id {
                        insertAt += 1
                    }
                }
                cue.parentID = anchorCue.parentID
                show.cues.insert(cue, at: insertAt)
            } else {
                show.cues.append(cue)
            }
        }
        document.selection = [cue.id]
    }

    /// Drag-reorder with structure maintenance: moved plain cues adopt the
    /// group they land in; group headers travel with their children; every
    /// child block is re-glued directly after its header.
    static func moveCues(in document: ShowDocumentController, from source: IndexSet, to destination: Int) {
        document.mutate { show in
            let movedIDs = source.map { show.cues[$0].id }
            var cues = show.cues
            cues.move(fromOffsets: source, toOffset: destination)

            // Moved plain cues adopt the group context at the landing spot.
            for id in movedIDs {
                guard let index = cues.firstIndex(where: { $0.id == id }) else { continue }
                if case .group = cues[index].body {
                    cues[index].parentID = nil   // groups stay top-level (single-level nesting in UI)
                    continue
                }
                let above = index > 0 ? cues[index - 1] : nil
                if let above {
                    if case .group = above.body {
                        cues[index].parentID = above.id
                    } else {
                        cues[index].parentID = above.parentID
                    }
                } else {
                    cues[index].parentID = nil
                }
            }
            show.cues = normalized(cues)
        }
    }

    /// Restore the flat-list invariant: each group's children immediately
    /// follow their header, in stable order; orphans become top-level.
    static func normalized(_ cues: [Cue]) -> [Cue] {
        let groupIDs = Set(cues.compactMap { cue -> UUID? in
            if case .group = cue.body { return cue.id }
            return nil
        })
        var repaired = cues
        for index in repaired.indices {
            if let parent = repaired[index].parentID, !groupIDs.contains(parent) {
                repaired[index].parentID = nil
            }
        }
        var childrenByParent: [UUID: [Cue]] = [:]
        for cue in repaired {
            if let parent = cue.parentID {
                childrenByParent[parent, default: []].append(cue)
            }
        }
        var result: [Cue] = []
        for cue in repaired where cue.parentID == nil {
            result.append(cue)
            if case .group = cue.body {
                result.append(contentsOf: childrenByParent[cue.id] ?? [])
            }
        }
        return result
    }

    /// Create cues from files dragged into the list. Returns how many files
    /// were skipped as non-media. `insertAtCueIndex` nil = append.
    @discardableResult
    static func importMedia(urls: [URL], at insertAtCueIndex: Int?, into document: ShowDocumentController) -> Int {
        var newCues: [Cue] = []
        var skipped = 0
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension) else { skipped += 1; continue }
            let media = MediaReference(fileURL: url, showFolder: document.showFolder)
            let body: CueBody? = if type.conforms(to: .movie) || type.conforms(to: .video) {
                .video(VideoBody(media: media, outputGroupID: defaultOutputGroupID(in: document)))
            } else if type.conforms(to: .audio) {
                .audio(AudioBody(media: media))
            } else {
                nil
            }
            guard let body else { skipped += 1; continue }
            newCues.append(Cue(number: "", body: body))   // numbered below, in document order
        }
        guard !newCues.isEmpty else { return skipped }

        document.mutate { show in
            var index = insertAtCueIndex.map { min($0, show.cues.count) } ?? show.cues.count
            // Dropping inside a group's child block joins the group.
            let parentID: UUID? = {
                guard index > 0, index <= show.cues.count else { return nil }
                let above = show.cues[index - 1]
                if case .group = above.body { return nil }   // right under a header: stay top-level on drop
                return above.parentID
            }()
            for var cue in newCues {
                cue.number = show.nextCueNumber()
                cue.parentID = parentID
                show.cues.insert(cue, at: index)
                index += 1
            }
        }
        document.selection = Set(newCues.map(\.id))
        return skipped
    }

    // MARK: - Copy / paste / duplicate

    static let cuesUTType = UTType(exportedAs: "com.marcotempest.stagewizard.cues", conformingTo: .json)

    /// The selection plus children of selected groups, in document order.
    static func copyableCues(in document: ShowDocumentController) -> [Cue] {
        let selection = document.selection
        guard !selection.isEmpty else { return [] }
        var ids = selection
        for cue in document.show.cues where cue.parentID.map(selection.contains) == true {
            ids.insert(cue.id)
        }
        return document.show.cues.filter { ids.contains($0.id) }
    }

    static func encodeCues(_ cues: [Cue]) -> Data? {
        try? JSONEncoder().encode(cues)
    }

    static func decodeCues(_ data: Data) -> [Cue]? {
        try? JSONDecoder().decode([Cue].self, from: data)
    }

    /// Fresh identities for pasted cues: every id is regenerated; parentID,
    /// timeline offsets, and fade/stop targets are remapped when they point
    /// INSIDE the pasted set. Targets outside keep aiming at the originals;
    /// a child pasted without its group becomes top-level.
    static func remappedForPaste(_ source: [Cue]) -> [Cue] {
        var idMap: [UUID: UUID] = [:]
        for cue in source {
            idMap[cue.id] = UUID()
        }
        return source.map { cue in
            var copy = cue
            copy.id = idMap[cue.id]!
            copy.parentID = cue.parentID.flatMap { idMap[$0] }
            switch copy.body {
            case .group(var body):
                body.childOffsets = Dictionary(uniqueKeysWithValues:
                    body.childOffsets.compactMap { key, value in idMap[key].map { ($0, value) } }
                )
                copy.body = .group(body)
            case .fade(var body):
                if let target = body.targetID, let remapped = idMap[target] {
                    body.targetID = remapped
                }
                copy.body = .fade(body)
            case .stop(var body):
                if let target = body.targetID, let remapped = idMap[target] {
                    body.targetID = remapped
                }
                copy.body = .stop(body)
            default:
                break
            }
            return copy
        }
    }

    /// Insert remapped copies after the current selection (group-block aware),
    /// renumbering top-level cues; children keep the group-relative numbers.
    static func pasteCues(_ source: [Cue], into document: ShowDocumentController) {
        guard !source.isEmpty else { return }
        let pasted = remappedForPaste(source)
        document.mutate { show in
            var insertAt = show.cues.count
            let selectedIndexes = document.selection.compactMap { show.indexOfCue(withID: $0) }
            if let anchor = selectedIndexes.max() {
                let anchorCue = show.cues[anchor]
                insertAt = anchor + 1
                if case .group = anchorCue.body {
                    while insertAt < show.cues.count, show.cues[insertAt].parentID == anchorCue.id {
                        insertAt += 1
                    }
                }
            }
            for var cue in pasted {
                if cue.parentID == nil {
                    cue.number = show.nextCueNumber()
                }
                show.cues.insert(cue, at: insertAt)
                insertAt += 1
            }
        }
        document.selection = Set(pasted.map(\.id))
    }

    static func duplicateSelection(in document: ShowDocumentController) {
        pasteCues(copyableCues(in: document), into: document)
    }

    static func deleteSelection(in document: ShowDocumentController) {
        guard !document.selection.isEmpty else { return }
        document.mutate { show in
            var doomed = document.selection
            // Deleting a group deletes its children.
            for cue in show.cues where cue.parentID.map(doomed.contains) == true {
                doomed.insert(cue.id)
            }
            show.cues.removeAll { doomed.contains($0.id) }
        }
        document.selection = []
    }
}
