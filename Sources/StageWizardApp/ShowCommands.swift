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
            Menu("Open Recent") {
                ForEach(app.recentShows, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        document.open(url: url)
                    }
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
                }
                if !app.recentShows.isEmpty {
                    Divider()
                }
                Button("Clear Menu") {
                    NSDocumentController.shared.clearRecentDocuments(nil)
                    app.refreshRecents()
                }
                .disabled(app.recentShows.isEmpty)
            }
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
            Button("Add Slides from Deck…") { SlideDeckImporter.importDeckViaPanel(into: document, app: app) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Button("Add Image Cue…") { CueFactory.addMediaCue(kind: .image, to: document) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(app.isShowMode)
            Divider()
            Button("Renumber All Cues") { CueFactory.renumberAll(in: document) }
                .disabled(app.isShowMode)
            Divider()
            Button("Duplicate Selected Cues") { CueFactory.duplicateSelection(in: document) }
                .keyboardShortcut("d")
                .disabled(app.isShowMode)
            Button("Delete Selected Cues") { CueFactory.deleteSelection(in: document) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.isShowMode)
        }
    }
}

/// Creation/removal helpers shared by menus, toolbar, and context menus.
@MainActor
enum CueFactory {
    enum MediaKind {
        case audio, video, image
    }

    static func addMediaCue(kind: MediaKind, to document: ShowDocumentController) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        switch kind {
        case .audio:
            panel.allowedContentTypes = [.audio]
            panel.message = "Choose audio files"
        case .video:
            panel.allowedContentTypes = [.movie, .video]
            panel.message = "Choose video files"
        case .image:
            panel.allowedContentTypes = [.image]
            panel.message = "Choose image files"
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        for url in panel.urls {
            let media = MediaReference(fileURL: url, showFolder: document.showFolder)
            let body: CueBody = switch kind {
            case .audio: .audio(AudioBody(media: media))
            case .video: .video(VideoBody(media: media, outputGroupID: defaultOutputGroupID(in: document)))
            case .image: .image(ImageBody(media: media, outputGroupID: defaultOutputGroupID(in: document)))
            }
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

    /// Top-to-bottom renumber: top-level cues 10, 20, 30…; children take
    /// "<parent>.1", "<parent>.2"… Numbers are display-only (targets use
    /// UUIDs), so this never breaks references.
    static func renumberAll(in document: ShowDocumentController) {
        document.mutate { show in
            show.cues = renumbered(show.cues)
        }
    }

    static func renumbered(_ cues: [Cue]) -> [Cue] {
        var result = cues
        var topNumber = 0
        var parentNumbers: [UUID: String] = [:]
        var childCounters: [UUID: Int] = [:]
        for index in result.indices {
            if let parentID = result[index].parentID {
                let count = (childCounters[parentID] ?? 0) + 1
                childCounters[parentID] = count
                let parentNumber = parentNumbers[parentID] ?? "?"
                result[index].number = "\(parentNumber).\(count)"
            } else {
                topNumber += 10
                result[index].number = "\(topNumber)"
                parentNumbers[result[index].id] = "\(topNumber)"
            }
        }
        return result
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

    /// Group membership for content landing at a seam in the flat cue
    /// array, judged by BOTH neighbors. Strictly inside a group's child
    /// block (or directly under its open header) joins the group; every
    /// block boundary — including the seam right below a group's last
    /// child — is top-level. So dropping just below a group pulls a child
    /// OUT, and nothing dropped after a group is ever absorbed into it.
    static func landingParent(above: Cue?, below: Cue?) -> UUID? {
        guard let above else { return nil }
        if case .group(let body) = above.body {
            // Under an open header is the deliberate "into the group" spot;
            // under a collapsed header everything lands outside.
            return body.collapsed ? nil : above.id
        }
        guard let parent = above.parentID else { return nil }
        return below?.parentID == parent ? parent : nil
    }

    /// Nearest index at or after `index` that is NOT inside a group's child
    /// block — where a top-level block (a group header + children) may be
    /// inserted without breaking the children-follow-header invariant.
    static func topLevelInsertionIndex(at index: Int, in cues: [Cue]) -> Int {
        var index = min(max(index, 0), cues.count)
        while index < cues.count, cues[index].parentID != nil {
            index += 1
        }
        return index
    }

    /// Drag-reorder with structure maintenance: the moved run is parented by
    /// the seam it lands in (see `landingParent`); group headers travel with
    /// their children; every child block is re-glued after its header.
    static func moveCues(in document: ShowDocumentController, from source: IndexSet, to destination: Int) {
        document.mutate { show in
            // A moved header takes its whole child block along, so children
            // keep their order no matter which rows were physically dragged.
            var expanded = source
            for offset in source {
                if case .group = show.cues[offset].body {
                    let headerID = show.cues[offset].id
                    for index in show.cues.indices where show.cues[index].parentID == headerID {
                        expanded.insert(index)
                    }
                }
            }
            let movedIDs = Set(expanded.map { show.cues[$0].id })
            var cues = show.cues
            cues.move(fromOffsets: expanded, toOffset: destination)

            // The moved cues are now one contiguous run — judge the landing
            // seam once, by the unmoved neighbors on either side of the run.
            let indexes = cues.indices.filter { movedIDs.contains(cues[$0].id) }
            guard let first = indexes.first, let last = indexes.last else { return }
            let landing = landingParent(
                above: first > 0 ? cues[first - 1] : nil,
                below: last + 1 < cues.count ? cues[last + 1] : nil
            )
            let movedGroupIDs = Set(indexes.compactMap { index -> UUID? in
                if case .group = cues[index].body { return cues[index].id }
                return nil
            })
            for index in indexes {
                if case .group = cues[index].body {
                    cues[index].parentID = nil   // groups stay top-level (single-level nesting in UI)
                } else if let parent = cues[index].parentID, movedGroupIDs.contains(parent) {
                    // Child dragged together with its own header: it travels
                    // with its group, wherever the group lands.
                    continue
                } else {
                    cues[index].parentID = landing
                }
            }
            show.cues = normalized(cues)
        }
    }

    /// Explicit escape hatch for drag-averse structure edits: selected
    /// children pop out to top level, landing right after their group block.
    static func moveOutOfGroup(in document: ShowDocumentController) {
        let selection = document.selection
        document.mutate { show in
            for index in show.cues.indices where selection.contains(show.cues[index].id) {
                if case .group = show.cues[index].body { continue }
                show.cues[index].parentID = nil
            }
            show.cues = normalized(show.cues)
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
            } else if type.conforms(to: .image) {
                .image(ImageBody(media: media, outputGroupID: defaultOutputGroupID(in: document)))
            } else {
                nil
            }
            guard let body else { skipped += 1; continue }
            newCues.append(Cue(number: "", body: body))   // numbered below, in document order
        }
        guard !newCues.isEmpty else { return skipped }

        document.mutate { show in
            var index = insertAtCueIndex.map { min($0, show.cues.count) } ?? show.cues.count
            // Files join a group only when dropped strictly inside its child
            // block (or right under its open header) — block boundaries are
            // top-level, so nothing is absorbed by dropping below a group.
            let parentID = landingParent(
                above: index > 0 ? show.cues[index - 1] : nil,
                below: index < show.cues.count ? show.cues[index] : nil
            )
            for var cue in newCues {
                cue.number = show.nextCueNumber()
                cue.parentID = parentID
                show.cues.insert(cue, at: index)
                index += 1
            }
            show.cues = normalized(show.cues)
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
