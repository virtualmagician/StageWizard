import SwiftUI
import UniformTypeIdentifiers

/// The main cue list: flat document order with indented children,
/// collapsible groups, full-row color tags, Target/Duration/Post-Wait columns,
/// inline-editable number and name, drag reorder, and media drag-import.
struct CueListView: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app

    private struct Row: Identifiable {
        let cue: Cue
        let depth: Int
        var id: UUID { cue.id }
    }

    /// Visible rows: children of collapsed groups are hidden.
    private var rows: [Row] {
        var result: [Row] = []
        var collapsedGroups: Set<UUID> = []
        for cue in document.show.cues {
            if let parent = cue.parentID {
                if collapsedGroups.contains(parent) { continue }
                result.append(Row(cue: cue, depth: 1))
            } else {
                result.append(Row(cue: cue, depth: 0))
                if case .group(let body) = cue.body, body.collapsed {
                    collapsedGroups.insert(cue.id)
                }
            }
        }
        return result
    }

    var body: some View {
        @Bindable var document = document
        let rows = rows
        VStack(spacing: 0) {
            header
            List(selection: $document.selection) {
                ForEach(rows) { row in
                    CueRowView(cueID: row.cue.id, depth: row.depth)
                        .tag(row.cue.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(row.cue))
                        .moveDisabled(app.isShowMode)
                }
                .onMove { source, destination in
                    guard !app.isShowMode else { return }
                    moveRows(rows: rows, from: source, to: destination)
                }
                .onInsert(of: [UTType.fileURL]) { index, providers in
                    guard !app.isShowMode else { return }
                    importDropped(providers: providers, atRowIndex: index, rows: rows)
                }
            }
            .listStyle(.plain)
            .onCopyCommand {
                copyProviders()
            }
            .onCutCommand {
                let providers = copyProviders()
                if !providers.isEmpty {
                    CueFactory.deleteSelection(in: document)
                }
                return providers
            }
            .onPasteCommand(of: [CueFactory.cuesUTType]) { providers in
                pasteFrom(providers)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, ids.count == 1 {
                    Button("Fire This Cue Now") {
                        app.transport.fire(cueID: id)
                    }
                    Divider()
                }
                if !app.isShowMode {
                    if ids.contains(where: { document.show.cue(withID: $0)?.parentID != nil }) {
                        Button("Move Out of Group") {
                            document.selection = ids
                            CueFactory.moveOutOfGroup(in: document)
                        }
                    }
                    Button("Duplicate") {
                        document.selection = ids
                        CueFactory.duplicateSelection(in: document)
                    }
                    Button("Delete") {
                        document.selection = ids
                        CueFactory.deleteSelection(in: document)
                    }
                }
            }
        }
        .background(Theme.listBackground)
    }

    // MARK: - Row background (full-row color tags)

    private func rowBackground(_ cue: Cue) -> some View {
        let isSelected = document.selection.contains(cue.id)
        let isGroup = if case .group = cue.body { true } else { false }
        let tint = tagColor(cue.colorTag)
        return ZStack {
            if let tint {
                tint.opacity(isGroup ? 0.30 : 0.22)
            } else if isGroup {
                Theme.groupRowBackground
            }
            // A group with live children glows — vital when it's collapsed
            // and the running cues are hidden inside.
            if isGroup && groupHasActiveCues(cue) {
                Theme.standby.opacity(0.16)
            }
            if isSelected {
                Theme.selectionOverlay
            }
        }
    }

    /// True while the group instance itself or any child instance is live.
    private func groupHasActiveCues(_ group: Cue) -> Bool {
        app.transport.registry.instances.contains { instance in
            !instance.state.isTerminal
                && (instance.cue.id == group.id || instance.cue.parentID == group.id)
        }
    }

    // MARK: - Reorder / drop with visible-row → cue-index mapping

    private func moveRows(rows: [Row], from source: IndexSet, to destination: Int) {
        // Map visible-row offsets back to indexes in the flat cues array.
        let cueIndexes = IndexSet(source.compactMap { rowIndex in
            document.show.indexOfCue(withID: rows[rowIndex].cue.id)
        })
        let destinationCueIndex = destination < rows.count
            ? (document.show.indexOfCue(withID: rows[destination].cue.id) ?? document.show.cues.count)
            : document.show.cues.count
        CueFactory.moveCues(in: document, from: cueIndexes, to: destinationCueIndex)
    }

    // MARK: - Copy / cut / paste (Edit-menu integration; list-focus only)

    private func copyProviders() -> [NSItemProvider] {
        guard !app.isShowMode else { return [] }
        let cues = CueFactory.copyableCues(in: document)
        guard !cues.isEmpty, let data = CueFactory.encodeCues(cues) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: CueFactory.cuesUTType.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return [provider]
    }

    private func pasteFrom(_ providers: [NSItemProvider]) {
        guard !app.isShowMode, let provider = providers.first else { return }
        Task {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(
                    forTypeIdentifier: CueFactory.cuesUTType.identifier
                ) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, let cues = CueFactory.decodeCues(data) else { return }
            CueFactory.pasteCues(cues, into: document)
        }
    }

    private func importDropped(providers: [NSItemProvider], atRowIndex rowIndex: Int, rows: [Row]) {
        let insertAt = rowIndex < rows.count
            ? document.show.indexOfCue(withID: rows[rowIndex].cue.id)
            : nil
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadFileURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            // Presentation decks take the slide-import pipeline.
            let decks = urls.filter { SlideDeckImporter.isDeck($0) }
            let media = urls.filter { !SlideDeckImporter.isDeck($0) }
            for deck in decks {
                SlideDeckImporter.importDeck(url: deck, at: insertAt, into: document, app: app)
            }
            guard !media.isEmpty else { return }
            let skipped = CueFactory.importMedia(urls: media, at: insertAt, into: document)
            if skipped > 0 {
                app.pushWarning("\(skipped) dropped file\(skipped == 1 ? "" : "s") skipped — not audio, video, an image, or a deck.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 24)                        // status
            Text("").frame(width: 22)                        // type icon
            Text("№").frame(width: 56, alignment: .leading)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Target").frame(width: 52, alignment: .trailing)
            Text("Pre-Wait").frame(width: 74, alignment: .trailing)
            Text("Duration").frame(width: 80, alignment: .trailing)
            Text("Post-Wait").frame(width: 74, alignment: .trailing)
            Text("").frame(width: 30)                        // follow badge
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.headerBackground)
    }
}

// MARK: - Row

struct CueRowView: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID
    let depth: Int

    var body: some View {
        if let cue = document.cue(withID: cueID) {
            HStack(spacing: 8) {
                statusIcon(cue)
                    .frame(width: 24)
                Image(systemName: typeSymbol(cue.body))
                    .foregroundStyle(cue.armed ? .primary : .tertiary)
                    .frame(width: 22)
                Group {
                    if app.isShowMode {
                        Text(cue.number)
                    } else {
                        TextField("№", text: numberBinding)
                            .textFieldStyle(.plain)
                    }
                }
                .frame(width: 56, alignment: .leading)
                nameColumn(cue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(targetLabel(cue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                Text(cue.preWait > 0 ? Timecode.format(cue.preWait) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
                durationColumn(cue)
                    .frame(width: 80, alignment: .trailing)
                Text(postWaitLabel(cue.follow))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
                followBadge(cue.follow)
                    .frame(width: 30)
            }
            .padding(.leading, CGFloat(depth) * 24)
            .padding(.vertical, 3)
            .opacity(cue.armed ? 1 : 0.45)
        }
    }

    // MARK: Columns

    @ViewBuilder
    private func statusIcon(_ cue: Cue) -> some View {
        if app.transport.playheadID == cueID {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.standby)
                .help("Standing by")
        } else if isMediaBroken(cue) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
                .help("Media file missing — relink in the inspector")
        } else if isOutputMissing(cue) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
                .help("No video output assigned — pick one in the Output tab")
        } else if isActiveGroupRow(cue) {
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(Theme.standby)
                .help("Cues inside this group are playing")
        } else {
            Text("")
        }
    }

    private func isActiveGroupRow(_ cue: Cue) -> Bool {
        guard case .group = cue.body else { return false }
        return app.transport.registry.instances.contains { instance in
            !instance.state.isTerminal
                && (instance.cue.id == cue.id || instance.cue.parentID == cue.id)
        }
    }

    @ViewBuilder
    private func nameColumn(_ cue: Cue) -> some View {
        HStack(spacing: 5) {
            if case .group(let body) = cue.body {
                Button {
                    toggleCollapsed(cue)
                } label: {
                    Image(systemName: body.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                if app.isShowMode {
                    Text(cue.displayName)
                        .font(.body.weight(.semibold))
                } else {
                    TextField("Name", text: nameBinding, prompt: Text(cue.body.defaultName))
                        .textFieldStyle(.plain)
                        .font(.body.weight(.semibold))
                }
                if body.collapsed {
                    Text("\(document.show.children(of: cue.id).count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            } else if app.isShowMode {
                Text(cue.displayName)
            } else {
                TextField("Name", text: nameBinding, prompt: Text(cue.body.defaultName))
                    .textFieldStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func durationColumn(_ cue: Cue) -> some View {
        if case .camera = cue.body {
            Text("∞")
                .foregroundStyle(.secondary)
        } else if case .slide = cue.body {
            Text("∞")
                .foregroundStyle(.secondary)
        } else if case .image = cue.body {
            Text("∞")
                .foregroundStyle(.secondary)
        } else if let duration = DurationCache.shared.effectiveDuration(
            of: cue, in: document.show, showFolder: document.showFolder
        ) {
            Text(duration > 0 ? Timecode.format(duration) : "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    private func targetLabel(_ cue: Cue) -> String {
        let targetID: UUID? = switch cue.body {
        case .fade(let body): body.targetID
        case .stop(let body): body.targetID
        default: nil
        }
        guard let targetID else {
            if case .stop = cue.body { return "all" }
            return ""
        }
        return document.show.cue(withID: targetID)?.number ?? "?"
    }

    private func postWaitLabel(_ follow: FollowAction) -> String {
        if case .autoContinue(let postWait) = follow, postWait > 0 {
            return Timecode.format(postWait)
        }
        return ""
    }

    @ViewBuilder
    private func followBadge(_ follow: FollowAction) -> some View {
        switch follow {
        case .none:
            Text("")
        case .autoContinue:
            Image(systemName: "arrow.down")
                .foregroundStyle(Theme.standby)
                .help("Auto-continue: next cue fires after post-wait")
        case .autoFollow:
            Image(systemName: "arrow.down.to.line")
                .foregroundStyle(Theme.standby)
                .help("Auto-follow: next cue fires when this cue completes")
        }
    }

    // MARK: Helpers

    /// Video/camera cues must have a (still existing) output group.
    private func isOutputMissing(_ cue: Cue) -> Bool {
        let groupID: UUID??
        switch cue.body {
        case .video(let body): groupID = body.display == nil ? .some(body.outputGroupID) : nil
        case .camera(let body): groupID = body.display == nil ? .some(body.outputGroupID) : nil
        case .image(let body): groupID = .some(body.outputGroupID)
        case .slide(let body): groupID = .some(body.outputGroupID)
        default: return false
        }
        guard let groupID else { return false }   // legacy direct display: handled at arm
        guard let id = groupID else { return true }
        return document.show.settings.group(withID: id) == nil
    }

    private func isMediaBroken(_ cue: Cue) -> Bool {
        let media: MediaReference? = switch cue.body {
        case .audio(let body): body.media
        case .video(let body): body.media
        case .image(let body): body.media
        case .slide(let body): body.media
        default: nil
        }
        guard let media else { return false }
        return media.resolve(showFolder: document.showFolder) == nil
    }

    private func toggleCollapsed(_ cue: Cue) {
        document.updateCue(cue.id) { cue in
            if case .group(var body) = cue.body {
                body.collapsed.toggle()
                cue.body = .group(body)
            }
        }
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { document.cue(withID: cueID)?.number ?? "" },
            set: { newValue in document.updateCue(cueID) { $0.number = newValue } }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { document.cue(withID: cueID)?.name ?? "" },
            set: { newValue in
                document.updateCue(cueID) { $0.name = newValue.isEmpty ? nil : newValue }
            }
        )
    }
}

func typeSymbol(_ body: CueBody) -> String {
    switch body {
    case .audio: return "waveform"
    case .video: return "film"
    case .camera: return "video.fill"
    case .image: return "photo.fill"
    case .slide: return "photo"
    case .fade: return "dial.low"
    case .stop: return "stop.fill"
    case .group: return "folder"
    case .broken: return "exclamationmark.triangle"
    }
}

func tagColor(_ tag: String?) -> Color? {
    switch tag {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    default: return nil
    }
}

extension NSItemProvider {
    /// Async file-URL extraction preserving drop order. @MainActor so the
    /// non-Sendable provider never leaves the caller's isolation region.
    @MainActor
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
