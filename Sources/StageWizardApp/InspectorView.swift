import SwiftUI
import UniformTypeIdentifiers

/// Bottom inspector for the selected cue, organized in tabs.
/// Output tab is populated by the audio/video engine milestones.
struct InspectorView: View {
    @Environment(ShowDocumentController.self) private var document
    @State private var tab: Tab = .basics

    enum Tab: String, CaseIterable {
        case basics = "Basics"
        case text = "Text"
        case timeAndLevels = "Time & Levels"
        case timeline = "Timeline"
        case geometry = "Geometry"
        case output = "Output"
        case triggers = "Shortcut"

        /// Tabs relevant to each cue type (groups get Timeline).
        static func available(for body: CueBody) -> [Tab] {
            switch body {
            case .group: return [.basics, .timeline, .triggers]
            case .audio: return [.basics, .timeAndLevels, .output, .triggers]
            case .video, .camera, .image, .slide: return [.basics, .timeAndLevels, .geometry, .output, .triggers]
            case .text: return [.basics, .text, .timeAndLevels, .geometry, .output, .triggers]
            case .fade, .stop: return [.basics, .timeAndLevels, .triggers]
            case .broken: return [.basics]
            }
        }
    }

    var body: some View {
        Group {
            if let cueID = singleSelection, let cue = document.cue(withID: cueID) {
                let tabs = Tab.available(for: cue.body)
                let activeTab = tabs.contains(tab) ? tab : .basics
                VStack(spacing: 0) {
                    Picker("", selection: Binding(get: { activeTab }, set: { tab = $0 })) {
                        ForEach(tabs, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    Divider()
                    // The timeline scrolls itself (both axes) — wrapping it in
                    // the inspector's ScrollView would crush its height.
                    if activeTab == .timeline {
                        GroupTimelineTab(cueID: cueID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            switch activeTab {
                            case .basics:
                                BasicsTab(cueID: cueID)
                            case .text:
                                TextContentTab(cueID: cueID)
                            case .timeAndLevels:
                                TimeAndLevelsTab(cueID: cueID, body: cue.body)
                            case .output:
                                OutputTab(cueID: cueID, body: cue.body)
                            case .triggers:
                                TriggersTab(cueID: cueID)
                            case .geometry:
                                GeometryTab(cueID: cueID)
                            case .timeline:
                                EmptyView()
                            }
                        }
                    }
                }
            } else {
                Text(document.selection.isEmpty ? "No cue selected" : "\(document.selection.count) cues selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private var singleSelection: UUID? {
        document.selection.count == 1 ? document.selection.first : nil
    }
}

// MARK: - Basics

private struct BasicsTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID) {
            Form {
                HStack {
                    TextField("Number", text: bind(\.number) { $0.number = $1 })
                        .frame(width: 120)
                    TextField("Name", text: Binding(
                        get: { cue.name ?? "" },
                        set: { v in document.updateCue(cueID) { $0.name = v.isEmpty ? nil : v } }
                    ), prompt: Text(cue.body.defaultName))
                }
                MediaFileRow(cueID: cueID)
                TextField("Notes", text: bind(\.notes) { $0.notes = $1 }, axis: .vertical)
                    .lineLimit(2...4)
                HStack(spacing: 16) {
                    Toggle("Armed", isOn: Binding(
                        get: { cue.armed },
                        set: { v in document.updateCue(cueID) { $0.armed = v } }
                    ))
                    ColorTagPicker(cueID: cueID)
                }
                Divider()
                TimecodeField(label: "Pre-Cue", value: Binding(
                    get: { cue.preWait },
                    set: { v in document.updateCue(cueID) { $0.preWait = v } }
                ))
                FollowPicker(cueID: cueID)
            }
            .formStyle(.columns)
            .padding(12)
            // Drop a replacement file anywhere on this tab to relink the cue.
            .dropDestination(for: URL.self) { urls, _ in
                guard !app.isShowMode, let url = urls.first,
                      let cue = document.cue(withID: cueID),
                      MediaRelink.accepts(url, for: cue) else { return false }
                MediaRelink.replace(cueID: cueID, with: url, document: document)
                return true
            }
        }
    }

    private func bind(_ keyPath: KeyPath<Cue, String>, _ set: @escaping (inout Cue, String) -> Void) -> Binding<String> {
        Binding(
            get: { document.cue(withID: cueID)?[keyPath: keyPath] ?? "" },
            set: { v in document.updateCue(cueID) { set(&$0, v) } }
        )
    }
}

/// Relink/replace plumbing shared by the Basics media row and the
/// missing-media banner: which cues carry a swappable media file, which
/// file types they accept, and the one write path that swaps the reference.
@MainActor
enum MediaRelink {
    static func mediaReference(_ cue: Cue) -> MediaReference? {
        switch cue.body {
        case .audio(let body): return body.media
        case .video(let body): return body.media
        case .image(let body): return body.media
        default: return nil
        }
    }

    static func accepts(_ url: URL, for cue: Cue) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        switch cue.body {
        case .audio: return type.conforms(to: .audio)
        case .video: return type.conforms(to: .movie) || type.conforms(to: .video)
        case .image: return type.conforms(to: .image)
        default: return false
        }
    }

    static func replace(cueID: UUID, with url: URL, document: ShowDocumentController) {
        let newRef = MediaReference(fileURL: url, showFolder: document.showFolder)
        document.updateCue(cueID) { cue in
            switch cue.body {
            case .audio(var b): b.media = newRef; cue.body = .audio(b)
            case .video(var b): b.media = newRef; cue.body = .video(b)
            case .image(var b): b.media = newRef; cue.body = .image(b)
            default: break
            }
        }
    }

    static func choose(cue: Cue, document: ShowDocumentController) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = switch cue.body {
        case .audio: [.audio]
        case .image: [.image]
        default: [.movie, .video]
        }
        panel.message = "Choose the media file for cue \(cue.number)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replace(cueID: cue.id, with: url, document: document)
    }
}

/// Filename + found/missing status + always-available Choose… button for
/// audio/video/image cues (slides reconvert from their deck instead).
private struct MediaFileRow: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), let media = MediaRelink.mediaReference(cue) {
            let resolved = media.resolve(showFolder: document.showFolder)
            HStack(spacing: 8) {
                Image(systemName: resolved != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(resolved != nil ? Theme.standby : .orange)
                Text(media.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(resolved?.path ?? "Missing — was at \(media.absolutePath)")
                if resolved == nil {
                    Text("missing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(resolved == nil ? "Relink…" : "Change…") {
                    MediaRelink.choose(cue: cue, document: document)
                }
                .disabled(app.isShowMode)
                Text("or drop a file here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(
                (resolved == nil ? Color.orange.opacity(0.12) : Theme.insetBackground.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
    }
}

private struct FollowPicker: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    private enum Mode: String, CaseIterable {
        case none = "No follow"
        case autoContinue = "Auto-continue"
        case autoFollow = "Auto-follow"
    }

    var body: some View {
        if let cue = document.cue(withID: cueID) {
            HStack(spacing: 12) {
                Picker("Follow", selection: Binding(
                    get: {
                        switch cue.follow {
                        case .none: Mode.none
                        case .autoContinue: Mode.autoContinue
                        case .autoFollow: Mode.autoFollow
                        }
                    },
                    set: { (mode: Mode) in
                        document.updateCue(cueID) {
                            switch mode {
                            case .none: $0.follow = .none
                            case .autoContinue:
                                let postWait: TimeInterval =
                                    if case .autoContinue(let w) = cue.follow { w } else { 0 }
                                $0.follow = .autoContinue(postWait: postWait)
                            case .autoFollow: $0.follow = .autoFollow
                            }
                        }
                    }
                )) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .frame(width: 260)

                if case .autoContinue(let postWait) = cue.follow {
                    TimecodeField(label: "Post-Cue", value: Binding(
                        get: { postWait },
                        set: { v in document.updateCue(cueID) { $0.follow = .autoContinue(postWait: v) } }
                    ))
                }
            }
        }
    }
}

private struct ColorTagPicker: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    private static let tags: [String?] = [nil, "red", "crimson", "rose", "sky", "steel", "navy"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.tags, id: \.self) { tag in
                Button {
                    document.updateCue(cueID) { $0.colorTag = tag }
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tagColor(tag) ?? Color(.windowBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary, lineWidth: 1))
                        .overlay {
                            if document.cue(withID: cueID)?.colorTag == tag {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Time & Levels

private struct TimeAndLevelsTab: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID
    let body_: CueBody

    init(cueID: UUID, body: CueBody) {
        self.cueID = cueID
        self.body_ = body
    }

    var body: some View {
        switch body_ {
        case .audio, .video:
            MediaTimingForm(cueID: cueID)
        case .camera:
            CameraTimingForm(cueID: cueID)
        case .image:
            ImageTimingForm(cueID: cueID)
        case .text:
            TextTimingForm(cueID: cueID)
        case .slide:
            SlideTimingForm(cueID: cueID)
        case .fade:
            FadeForm(cueID: cueID)
        case .stop:
            StopForm(cueID: cueID)
        case .group:
            GroupTimelineTab(cueID: cueID)   // not reachable via tabs; safe fallback
        case .broken:
            Text("This cue type isn't supported by this version of StageWizard.")
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }
}

/// Shared timing/levels editing for audio + video cue bodies.
private struct MediaTimingForm: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID) {
            Form {
                trimEditor(for: cue)
                TimecodeField(label: "Start (in)", value: mediaBinding(\.startTime) { $0.startTime = max(0, $1) })
                HStack {
                    TimecodeField(label: "End (out)", value: Binding(
                        get: { mediaValues(cue)?.endTime ?? 0 },
                        set: { v in updateMedia { $0.endTime = v > 0 ? v : nil } }
                    ))
                    Text("0 = file end").font(.caption).foregroundStyle(.tertiary)
                }
                Divider()
                VolumeSlider(label: "Volume", value: mediaBinding(\.volumeDB) { $0.volumeDB = $1 })
                TimecodeField(label: "Fade in", value: mediaBinding(\.fadeInDuration) { $0.fadeInDuration = max(0, $1) })
                TimecodeField(label: "Fade out", value: mediaBinding(\.fadeOutDuration) { $0.fadeOutDuration = max(0, $1) })
                Divider()
                HStack(spacing: 16) {
                    Stepper(
                        "Play count: \(mediaValues(cue)?.playCount ?? 1)",
                        value: mediaBinding(\.playCount) { $0.playCount = max(1, $1) },
                        in: 1...999
                    )
                    Toggle("Loop forever", isOn: mediaBinding(\.infiniteLoop) { $0.infiniteLoop = $1 })
                }
                if case .video(let video) = cue.body {
                    Picker("At end", selection: Binding(
                        get: { video.endBehavior },
                        set: { v in updateVideo { $0.endBehavior = v } }
                    )) {
                        Text("Hold last frame").tag(VideoEndBehavior.holdLastFrame)
                        Text("Stop and unload").tag(VideoEndBehavior.stopAndUnload)
                    }
                    .frame(width: 280)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    @ViewBuilder
    private func trimEditor(for cue: Cue) -> some View {
        let media: MediaReference? = switch cue.body {
        case .audio(let b): b.media
        case .video(let b): b.media
        default: nil
        }
        if let media {
            if let url = media.resolve(showFolder: document.showFolder) {
                switch cue.body {
                case .audio:
                    WaveformTrimEditor(
                        fileURL: url,
                        startTime: mediaBinding(\.startTime) { $0.startTime = max(0, $1) },
                        endTime: mediaBinding(\.endTime) { $0.endTime = $1 }
                    )
                case .video:
                    VideoTrimEditor(
                        fileURL: url,
                        startTime: mediaBinding(\.startTime) { $0.startTime = max(0, $1) },
                        endTime: mediaBinding(\.endTime) { $0.endTime = $1 }
                    )
                default:
                    EmptyView()
                }
            } else {
                HStack {
                    Label("Media file missing: \(media.fileName)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Relink…") { MediaRelink.choose(cue: cue, document: document) }
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Uniform access to the fields audio and video bodies share.
    private struct MediaValues {
        var startTime: TimeInterval
        var endTime: TimeInterval?
        var playCount: Int
        var infiniteLoop: Bool
        var volumeDB: Double
        var fadeInDuration: TimeInterval
        var fadeOutDuration: TimeInterval
    }

    private func mediaValues(_ cue: Cue) -> MediaValues? {
        switch cue.body {
        case .audio(let b):
            MediaValues(startTime: b.startTime, endTime: b.endTime, playCount: b.playCount,
                        infiniteLoop: b.infiniteLoop, volumeDB: b.volumeDB,
                        fadeInDuration: b.fadeInDuration, fadeOutDuration: b.fadeOutDuration)
        case .video(let b):
            MediaValues(startTime: b.startTime, endTime: b.endTime, playCount: b.playCount,
                        infiniteLoop: b.infiniteLoop, volumeDB: b.volumeDB,
                        fadeInDuration: b.fadeInDuration, fadeOutDuration: b.fadeOutDuration)
        default:
            nil
        }
    }

    private func updateMedia(_ change: (inout MediaFields) -> Void) {
        document.updateCue(cueID) { cue in
            switch cue.body {
            case .audio(var b):
                var fields = MediaFields(audio: b)
                change(&fields)
                fields.apply(to: &b)
                cue.body = .audio(b)
            case .video(var b):
                var fields = MediaFields(video: b)
                change(&fields)
                fields.apply(to: &b)
                cue.body = .video(b)
            default:
                break
            }
        }
    }

    private func updateVideo(_ change: (inout VideoBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .video(var b) = cue.body {
                change(&b)
                cue.body = .video(b)
            }
        }
    }

    private func mediaBinding<T>(
        _ get: @escaping (MediaValues) -> T,
        _ set: @escaping (inout MediaFields, T) -> Void
    ) -> Binding<T> where T: Sendable {
        Binding(
            get: {
                // Deleted-while-editing is reachable (field editor commits after
                // the cue is gone) — fall back to inert defaults, never crash.
                guard let cue = document.cue(withID: cueID), let values = mediaValues(cue) else {
                    return get(MediaValues(
                        startTime: 0, endTime: nil, playCount: 1, infiniteLoop: false,
                        volumeDB: 0, fadeInDuration: 0, fadeOutDuration: 0
                    ))
                }
                return get(values)
            },
            set: { v in updateMedia { set(&$0, v) } }
        )
    }

    /// Mutable overlay for the shared audio/video fields.
    struct MediaFields {
        var startTime: TimeInterval
        var endTime: TimeInterval?
        var playCount: Int
        var infiniteLoop: Bool
        var volumeDB: Double
        var fadeInDuration: TimeInterval
        var fadeOutDuration: TimeInterval

        init(audio b: AudioBody) {
            startTime = b.startTime; endTime = b.endTime; playCount = b.playCount
            infiniteLoop = b.infiniteLoop; volumeDB = b.volumeDB
            fadeInDuration = b.fadeInDuration; fadeOutDuration = b.fadeOutDuration
        }

        init(video b: VideoBody) {
            startTime = b.startTime; endTime = b.endTime; playCount = b.playCount
            infiniteLoop = b.infiniteLoop; volumeDB = b.volumeDB
            fadeInDuration = b.fadeInDuration; fadeOutDuration = b.fadeOutDuration
        }

        func apply(to b: inout AudioBody) {
            b.startTime = startTime; b.endTime = endTime; b.playCount = playCount
            b.infiniteLoop = infiniteLoop; b.volumeDB = volumeDB
            b.fadeInDuration = fadeInDuration; b.fadeOutDuration = fadeOutDuration
        }

        func apply(to b: inout VideoBody) {
            b.startTime = startTime; b.endTime = endTime; b.playCount = playCount
            b.infiniteLoop = infiniteLoop; b.volumeDB = volumeDB
            b.fadeInDuration = fadeInDuration; b.fadeOutDuration = fadeOutDuration
        }
    }
}

/// Camera cues run until stopped — only the edge fades are editable here.
private struct CameraTimingForm: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .camera(let camera) = cue.body {
            Form {
                Text("Live camera — runs until stopped by a stop cue, panic, or the Active Cues panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimecodeField(label: "Fade in", value: Binding(
                    get: { camera.fadeInDuration },
                    set: { v in update { $0.fadeInDuration = max(0, v) } }
                ))
                TimecodeField(label: "Fade out", value: Binding(
                    get: { camera.fadeOutDuration },
                    set: { v in update { $0.fadeOutDuration = max(0, v) } }
                ))
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func update(_ change: (inout CameraBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .camera(var b) = cue.body {
                change(&b)
                cue.body = .camera(b)
            }
        }
    }
}

/// Images hold until stopped — only the edge fades are editable here.
private struct ImageTimingForm: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .image(let image) = cue.body {
            Form {
                Text("Still image — holds until stopped by a stop cue, panic, or the Active Cues panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimecodeField(label: "Fade in", value: Binding(
                    get: { image.fadeInDuration },
                    set: { v in update { $0.fadeInDuration = max(0, v) } }
                ))
                TimecodeField(label: "Fade out", value: Binding(
                    get: { image.fadeOutDuration },
                    set: { v in update { $0.fadeOutDuration = max(0, v) } }
                ))
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func update(_ change: (inout ImageBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .image(var b) = cue.body {
                change(&b)
                cue.body = .image(b)
            }
        }
    }
}

private struct ImageOutputSettings: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .image(let image) = cue.body {
            Form {
                OutputGroupPicker(selection: Binding(
                    get: { image.outputGroupID },
                    set: { v in
                        document.updateCue(cueID) { cue in
                            if case .image(var b) = cue.body {
                                b.outputGroupID = v
                                cue.body = .image(b)
                            }
                        }
                    }
                ))
                if image.outputGroupID == nil {
                    Label("No output assigned — the image won't play.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }
}

/// The Text tab: rich editor + background controls, all pushing live.
private struct TextContentTab: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID
    @State private var editor = RichTextEditorController()
    @State private var fontSize: Double = 96
    @State private var lineHeight: Double = 1.0
    @State private var textColor: Color = .white

    var body: some View {
        if let cue = document.cue(withID: cueID), case .text(let text) = cue.body {
            VStack(alignment: .leading, spacing: 8) {
                formattingBar
                RichTextEditor(controller: editor, rtf: Binding(
                    get: { text.rtf },
                    set: { _ in }   // writes flow through onEdit for atomicity
                ), backgroundColor: text.backgroundColor, box: text.box, onEdit: { rtf, plain in
                    update { body in
                        body.rtf = rtf
                        body.plainPreview = String(plain.prefix(120))
                    }
                }, onBoxChanged: { rect in
                    update { $0.box = rect }
                })
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 16) {
                    Button("Fonts…") {
                        NSFontManager.shared.orderFrontFontPanel(nil)
                    }
                    .help("Full font browser — applies to the selection")

                    Toggle("Transparent background", isOn: Binding(
                        get: { text.backgroundColor == nil },
                        set: { transparent in
                            update { $0.backgroundColor = transparent ? nil : RGBAColor(red: 0, green: 0, blue: 0) }
                        }
                    ))

                    if let bg = text.backgroundColor {
                        ColorPicker("Background", selection: Binding(
                            get: { Color(red: bg.red, green: bg.green, blue: bg.blue, opacity: bg.alpha) },
                            set: { color in
                                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
                                update {
                                    $0.backgroundColor = RGBAColor(
                                        red: resolved.redComponent, green: resolved.greenComponent,
                                        blue: resolved.blueComponent, alpha: resolved.alphaComponent
                                    )
                                }
                            }
                        ), supportsOpacity: true)
                    }
                    Spacer()
                }
            }
            .padding(12)
            .disabled(app.isShowMode)
        }
    }

    /// Formatting controls act on the selection (or the whole text when
    /// nothing is selected) and write straight back through the editor.
    private var formattingBar: some View {
        HStack(spacing: 10) {
            Button {
                editor.toggleBold()
            } label: {
                Image(systemName: "bold")
            }
            .help("Bold")
            Button {
                editor.toggleItalic()
            } label: {
                Image(systemName: "italic")
            }
            .help("Italic")

            Divider().frame(height: 16)

            Button {
                editor.setAlignment(.left)
            } label: {
                Image(systemName: "text.alignleft")
            }
            .help("Align left")
            Button {
                editor.setAlignment(.center)
            } label: {
                Image(systemName: "text.aligncenter")
            }
            .help("Center")
            Button {
                editor.setAlignment(.right)
            } label: {
                Image(systemName: "text.alignright")
            }
            .help("Align right")

            Divider().frame(height: 16)

            Text("Size")
                .foregroundStyle(.secondary)
            TextField("", value: $fontSize, format: .number.precision(.fractionLength(0)))
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .onSubmit { editor.setFontSize(CGFloat(max(4, fontSize))) }
            Stepper("", value: $fontSize, in: 4...400, step: 4)
                .labelsHidden()
                .onChange(of: fontSize) { _, v in editor.setFontSize(CGFloat(max(4, v))) }

            Text("Line")
                .foregroundStyle(.secondary)
            Stepper(String(format: "%.2f", lineHeight), value: $lineHeight, in: 0.6...3.0, step: 0.05)
                .onChange(of: lineHeight) { _, v in editor.setLineHeight(CGFloat(v)) }
                .help("Line height multiple")

            ColorPicker("", selection: $textColor, supportsOpacity: true)
                .labelsHidden()
                .onChange(of: textColor) { _, v in
                    editor.setTextColor(NSColor(v))
                }
                .help("Text color — applies to the selection")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func update(_ change: (inout TextBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .text(var b) = cue.body {
                change(&b)
                cue.body = .text(b)
            }
        }
        app.pushText(cueID: cueID)
    }
}

/// Text holds until stopped — only the edge fades are editable here.
private struct TextTimingForm: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .text(let text) = cue.body {
            Form {
                Text("Text — holds until stopped by a stop cue, panic, or the Active Cues panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimecodeField(label: "Fade in", value: Binding(
                    get: { text.fadeInDuration },
                    set: { v in update { $0.fadeInDuration = max(0, v) } }
                ))
                TimecodeField(label: "Fade out", value: Binding(
                    get: { text.fadeOutDuration },
                    set: { v in update { $0.fadeOutDuration = max(0, v) } }
                ))
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func update(_ change: (inout TextBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .text(var b) = cue.body {
                change(&b)
                cue.body = .text(b)
            }
        }
    }
}

private struct TextOutputSettings: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .text(let text) = cue.body {
            Form {
                OutputGroupPicker(selection: Binding(
                    get: { text.outputGroupID },
                    set: { v in
                        document.updateCue(cueID) { cue in
                            if case .text(var b) = cue.body {
                                b.outputGroupID = v
                                cue.body = .text(b)
                            }
                        }
                    }
                ))
                if text.outputGroupID == nil {
                    Label("No output assigned — the text won't play.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }
}

/// Slides hold until stopped/replaced — fades + deck info + reconversion.
private struct SlideTimingForm: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .slide(let slide) = cue.body {
            Form {
                if let index = slide.slideIndex, let count = slide.slideCount {
                    Text("Slide \(index) of \(count) from “\(slide.deckName)” — holds until stopped; the next slide on the same output replaces it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TimecodeField(label: "Fade in", value: Binding(
                    get: { slide.fadeInDuration },
                    set: { v in update { $0.fadeInDuration = max(0, v) } }
                ))
                Toggle("Replace previous slide on this output", isOn: Binding(
                    get: { slide.replacesPreviousSlide },
                    set: { v in update { $0.replacesPreviousSlide = v } }
                ))
                if slide.sourceDeck != nil {
                    Button("Reconvert Deck from Source…") {
                        SlideDeckImporter.reconvert(cueID: cueID, document: document, app: app)
                    }
                    .disabled(app.isShowMode)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func update(_ change: (inout SlideBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .slide(var b) = cue.body {
                change(&b)
                cue.body = .slide(b)
            }
        }
    }
}

private struct SlideOutputSettings: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .slide(let slide) = cue.body {
            Form {
                OutputGroupPicker(selection: Binding(
                    get: { slide.outputGroupID },
                    set: { v in
                        document.updateCue(cueID) { cue in
                            if case .slide(var b) = cue.body {
                                b.outputGroupID = v
                                cue.body = .slide(b)
                            }
                        }
                    }
                ))
                if slide.outputGroupID == nil {
                    Label("No output assigned — the slide won't play.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }
}

private struct FadeForm: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .fade(let fade) = cue.body {
            Form {
                CueTargetPicker(label: "Fade target", target: Binding(
                    get: { fade.targetID },
                    set: { v in update { $0.targetID = v } }
                ), excluding: cueID)
                TimecodeField(label: "Duration", value: Binding(
                    get: { fade.duration },
                    set: { v in update { $0.duration = max(0, v) } }
                ))
                Picker("Curve", selection: Binding(
                    get: { fade.curve },
                    set: { v in update { $0.curve = v } }
                )) {
                    ForEach(FadeCurve.allCases, id: \.self) { Text($0.displayName) }
                }
                .frame(width: 260)
                VolumeSlider(label: "To volume", value: Binding(
                    get: { fade.toVolumeDB ?? silenceFloorDB },
                    set: { v in update { $0.toVolumeDB = v } }
                ))
                Toggle("Stop target when done", isOn: Binding(
                    get: { fade.stopTargetWhenDone },
                    set: { v in update { $0.stopTargetWhenDone = v } }
                ))
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func update(_ change: (inout FadeBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .fade(var b) = cue.body {
                change(&b)
                cue.body = .fade(b)
            }
        }
    }
}

private struct StopForm: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .stop(let stop) = cue.body {
            Form {
                CueTargetPicker(label: "Stop target", target: Binding(
                    get: { stop.targetID },
                    set: { v in update { $0.targetID = v } }
                ), excluding: cueID, allowAll: true)
                HStack {
                    TimecodeField(label: "Fade out over", value: Binding(
                        get: { stop.fadeOutTime },
                        set: { v in update { $0.fadeOutTime = max(0, v) } }
                    ))
                    Text("0 = hard stop").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func update(_ change: (inout StopBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .stop(var b) = cue.body {
                change(&b)
                cue.body = .stop(b)
            }
        }
    }
}

/// Picks another cue in the show as a fade/stop target.
struct CueTargetPicker: View {
    @Environment(ShowDocumentController.self) private var document
    let label: String
    @Binding var target: UUID?
    let excluding: UUID
    var allowAll = false

    var body: some View {
        Picker(label, selection: $target) {
            Text(allowAll ? "All playing cues" : "None").tag(nil as UUID?)
            ForEach(document.show.cues.filter { $0.id != excluding && $0.body.isMediaOrGroup }) { cue in
                Text("\(cue.number)  \(cue.displayName)").tag(cue.id as UUID?)
            }
        }
        .frame(maxWidth: 340)
    }
}

extension CueBody {
    var isMediaOrGroup: Bool {
        switch self {
        case .audio, .video, .camera, .image, .text, .slide, .group: return true
        case .fade, .stop, .broken: return false
        }
    }
}

// MARK: - Output (populated in M2/M3)

private struct OutputTab: View {
    let cueID: UUID
    let body_: CueBody

    init(cueID: UUID, body: CueBody) {
        self.cueID = cueID
        self.body_ = body
    }

    var body: some View {
        switch body_ {
        case .audio:
            AudioOutputSettingsView(cueID: cueID)
        case .video:
            VStack(alignment: .leading, spacing: 0) {
                VideoOutputSettingsView(cueID: cueID)
                VideoAudioDevicePicker(cueID: cueID)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        case .camera:
            CameraOutputSettings(cueID: cueID)
        case .image:
            ImageOutputSettings(cueID: cueID)
        case .text:
            TextOutputSettings(cueID: cueID)
        case .slide:
            SlideOutputSettings(cueID: cueID)
        default:
            Text("No output settings for this cue type.")
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }
}

/// Camera source, display, and fill mode for camera cues.
private struct CameraOutputSettings: View {
    @Environment(ShowDocumentController.self) private var document
    @Environment(AppModel.self) private var app
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .camera(let camera) = cue.body {
            Form {
                HStack {
                    Picker("Camera", selection: Binding(
                        get: { camera.cameraUID },
                        set: { uid in
                            let name = uid.flatMap { u in
                                CameraDeviceManager.shared.cameras.first { $0.uid == u }?.name
                            }
                            update { $0.cameraUID = uid; $0.cameraName = name }
                        }
                    )) {
                        Text("Default camera").tag(nil as String?)
                        ForEach(CameraDeviceManager.shared.cameras) { camera in
                            Text(camera.name).tag(camera.uid as String?)
                        }
                        if let uid = camera.cameraUID,
                           !CameraDeviceManager.shared.cameras.contains(where: { $0.uid == uid }) {
                            Text("\(camera.cameraName ?? "Saved camera") (not connected)")
                                .tag(uid as String?)
                        }
                    }
                    .frame(maxWidth: 400)
                    Button {
                        CameraDeviceManager.shared.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan cameras")
                }

                OutputGroupPicker(selection: Binding(
                    get: { camera.outputGroupID },
                    set: { v in
                        update {
                            $0.outputGroupID = v
                            $0.display = nil   // group assignment supersedes legacy pinning
                        }
                    }
                ))

                Text("Placement and scaling moved to the Geometry tab.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()
                Text("Effects")
                    .font(.headline)
                Toggle("Remove background (person segmentation)", isOn: Binding(
                    get: { camera.effects.segmentation },
                    set: { v in updateEffects { $0.segmentation = v } }
                ))
                Text("The background turns transparent — put video or images on a LOWER layer (Geometry tab) and they show behind the performer.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle("Magic dust on hands", isOn: Binding(
                    get: { camera.effects.magicDust },
                    set: { v in updateEffects { $0.magicDust = v } }
                ))
                if camera.effects.magicDust {
                    HStack(spacing: 8) {
                        Picker("Emitter", selection: Binding(
                            get: {
                                camera.effects.dustEmitter != nil
                                    ? "custom"
                                    : (camera.effects.dustPreset ?? DustPresets.defaultName)
                            },
                            set: { choice in
                                guard choice != "custom" else { return }
                                updateEffects {
                                    $0.dustPreset = choice
                                    $0.dustEmitter = nil
                                }
                            }
                        )) {
                            ForEach(DustPresets.names, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            if let custom = camera.effects.dustEmitter {
                                Text("Custom: \(custom.fileName)").tag("custom")
                            }
                        }
                        .frame(maxWidth: 280)

                        Button("Choose .pex…") {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.allowedContentTypes = [.init(filenameExtension: "pex") ?? .xml]
                            panel.message = "Choose a Particle Designer emitter"
                            if panel.runModal() == .OK, let url = panel.url {
                                let ref = MediaReference(fileURL: url, showFolder: document.showFolder)
                                updateEffects { $0.dustEmitter = ref }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Size")
                        Slider(value: Binding(
                            get: { camera.effects.dustScale },
                            set: { v in updateEffects { $0.dustScale = v } }
                        ), in: 0.5...10)
                        .frame(maxWidth: 240)
                        Text(String(format: "×%.1f", camera.effects.dustScale))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Text("Particles follow the performer's hands — pick a preset or any Particle Designer .pex.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }

    private func updateEffects(_ change: (inout CameraEffects) -> Void) {
        document.updateCue(cueID) { cue in
            if case .camera(var b) = cue.body {
                change(&b.effects)
                cue.body = .camera(b)
            }
        }
        app.pushEffects(cueID: cueID)
    }

    private func update(_ change: (inout CameraBody) -> Void) {
        document.updateCue(cueID) { cue in
            if case .camera(var b) = cue.body {
                change(&b)
                cue.body = .camera(b)
            }
        }
    }
}

/// Routes a video cue's embedded audio track to a chosen output device.
private struct VideoAudioDevicePicker: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID), case .video(let video) = cue.body {
            HStack {
                Picker("Audio to", selection: Binding(
                    get: { video.audioDeviceUID },
                    set: { uid in
                        let name = uid.flatMap { u in
                            AudioDeviceManager.shared.outputDevices.first { $0.uid == u }?.name
                        }
                        document.updateCue(cueID) { cue in
                            if case .video(var b) = cue.body {
                                b.audioDeviceUID = uid
                                b.audioDeviceName = name
                                cue.body = .video(b)
                            }
                        }
                    }
                )) {
                    Text("System Default").tag(nil as String?)
                    ForEach(AudioDeviceManager.shared.outputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                    if let uid = video.audioDeviceUID,
                       !AudioDeviceManager.shared.outputDevices.contains(where: { $0.uid == uid }) {
                        Text("\(video.audioDeviceName ?? "Saved device") (not connected)")
                            .tag(uid as String?)
                    }
                }
                .frame(maxWidth: 400)
            }
        }
    }
}

// MARK: - Triggers

private struct TriggersTab: View {
    @Environment(ShowDocumentController.self) private var document
    let cueID: UUID

    var body: some View {
        if let cue = document.cue(withID: cueID) {
            Form {
                HStack {
                    Text("Hotkey")
                    ShortcutRecorderField(binding: cue.hotkey) { newBinding in
                        document.mutate { show in
                            // One key, one meaning: steal from other cue hotkeys
                            // AND from transport bindings.
                            if let newBinding {
                                for index in show.cues.indices where show.cues[index].hotkey == newBinding {
                                    show.cues[index].hotkey = nil
                                }
                                for action in ShortcutAction.allCases where show.settings.keyBindings[action] == newBinding {
                                    show.settings.keyBindings[action] = nil
                                }
                            }
                            if let index = show.indexOfCue(withID: cueID) {
                                show.cues[index].hotkey = newBinding
                            }
                        }
                    }
                    .id(cueID)   // new recorder per cue: a capture can't outlive the selection
                    Text("Fires this cue directly, from anywhere in the show.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.columns)
            .padding(12)
        }
    }
}

// MARK: - Small controls

/// Text field that displays/parses operator timecode ("1:23.5").
struct TimecodeField: View {
    let label: String
    @Binding var value: TimeInterval
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label)
            TextField("0.000", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 116)   // fits "12:34.567" without clipping
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onAppear { text = Timecode.format(value) }
                .onChange(of: value) { _, newValue in
                    if !focused { text = Timecode.format(newValue) }
                }
        }
    }

    private func commit() {
        if let parsed = Timecode.parse(text) {
            value = parsed
        }
        text = Timecode.format(value)
    }
}

/// dB slider with unity detent display, -60…+12 range, -inf at the bottom.
struct VolumeSlider: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
            Slider(value: sliderBinding, in: -60...12)
                .frame(maxWidth: 260)
            Text(value <= silenceFloorDB ? "-∞ dB" : String(format: "%+.1f dB", value))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { max(value, -60) },
            set: { value = $0 <= -59.9 ? silenceFloorDB : $0 }
        )
    }
}
