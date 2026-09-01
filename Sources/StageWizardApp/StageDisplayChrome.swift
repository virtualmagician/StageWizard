import AppKit
import QuartzCore
import SwiftUI

/// D23: the "ATEM-style multiview" visual language shared by every stage
/// display pane — tile chrome (near-black background, thin neutral border,
/// tiny corner radius), a bottom-center label bar, and tally-colored
/// borders (red = on air, green = standing by). Pure restyle of
/// `StageDisplayWindow.swift`'s existing panes: no model changes, no new
/// settings, layout rects/editor untouched.
///
/// A program pane's LIVE mirrored content is a raw CALayer hosted outside
/// SwiftUI entirely (`StageDisplayController.programHostLayers`), so its
/// tally border + label can't be drawn by ordinary SwiftUI view modifiers —
/// they'd be painted UNDER the mirror and invisible the moment a cue goes
/// live. Both the SwiftUI-side constants below and their `CGColor`
/// AppKit-side twins exist for exactly that reason: `MultiviewTile` (SwiftUI)
/// styles every other pane, while `StageDisplayController.ProgramOverlay`
/// (a plain `CALayer`, see `StageDisplayWindow.swift`) paints the same look
/// directly above a program pane's mirrored content.
enum StageDisplayChrome {
    /// Near-black tile background — deliberately lifted a touch off the
    /// window's pure-black ground (`Color.black` in
    /// `StageDisplayContentView.body`) so the grid of tiles actually reads
    /// as tiles. The gaps BETWEEN tiles (down to the pure-black ground) ARE
    /// the bezel — no dedicated "gap"/"grid line" view is needed.
    static let tileBackground = Color(red: 0.05, green: 0.05, blue: 0.05)
    static let neutralBorder = Color(white: 0.23)
    static let cornerRadius: CGFloat = 3

    static let labelBackground = Color.black.opacity(0.85)
    static let labelText = Color.white

    // MARK: AppKit/CoreAnimation twins (StageDisplayController's raw CALayer chrome)

    static let neutralBorderCG = CGColor(gray: 0.23, alpha: 1)
    static let labelBackgroundCG = CGColor(gray: 0, alpha: 0.85)
    static let labelTextCG = CGColor(gray: 1, alpha: 1)
}

/// D24: the ONE typography system every stage-display pane draws from —
/// system MONOSPACED throughout, no exceptions. Before this, the
/// standing-by pane's cue NAME (and a few other labels) fell back to the
/// default proportional sans while every digit/label around them was
/// already monospaced — Marco flagged it directly from screenshots as
/// visually inconsistent, and the mismatch is also what let that name run
/// long enough to collide with the tile's own "STANDING BY" label strip
/// (see `MultiviewTile`'s content-inset fix, same D24 pass). Every role
/// here fixes the WEIGHT and FAMILY only; every call site still supplies
/// its own size, proportional to its pane's rect exactly as before.
///
/// `labelNSFont(ofSize:)` is the AppKit twin, for the one piece of stage-
/// display text that isn't SwiftUI: a program pane's live tally label is a
/// raw `CATextLayer` painted above the mirrored content
/// (`StageDisplayController.ProgramOverlay`, see `StageDisplayWindow.swift`)
/// — it must match `label(_:)` exactly so a program tile's label reads
/// identically to every other tile's.
enum StageDisplayTypography {
    /// Tile label strips (`MultiviewLabelBar`) — medium weight; tracking
    /// and uppercasing are applied by the caller, unchanged from D23.
    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    /// Clock / show-timer digits — bold, tabular. `design: .monospaced`
    /// already gives tabular figures; callers additionally apply
    /// `.monospacedDigit()`, belt-and-suspenders.
    static func digits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    /// The standing-by pane's cue NUMBER — regular weight, secondary (the
    /// caller applies the muted color).
    static func standingByNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// The standing-by pane's cue NAME — bold, monospaced. This is the
    /// exact role that used to fall back to the default proportional sans.
    static func standingByName(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    /// Everything else on the display — notes, running-row names,
    /// placeholders, secondary readouts — monospaced, regular weight
    /// unless the caller asks for more emphasis.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// AppKit twin of `label(_:)` for the program pane's `CATextLayer`
    /// group-name label.
    static func labelNSFont(ofSize size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .medium)
    }
}

/// D23: which "tally" a stage-display pane currently shows — mirrors a
/// broadcast multiview's red (on air) / green (preview / standing by)
/// convention. A pure, dependency-free decision (no SwiftUI/AppKit types),
/// so it's directly unit-testable; `borderColor`/`borderWidth`/
/// `borderColorCG` below are where it's mapped onto each renderer's own
/// color type.
enum StageDisplayTally: Equatable {
    case live       // red — program pane currently mirroring content ("on air")
    case standby    // green — standing-by pane armed with a cue
    case neutral    // dark neutral — every other pane, always

    /// Program panes: red while `StageDisplayController.paneHasContent`
    /// reports the group's mirrored layer is actually painting something;
    /// neutral once nothing is mirrored (idle "NO SOURCE" placeholder, or
    /// the pane's group was deleted).
    static func program(hasContent: Bool) -> StageDisplayTally {
        hasContent ? .live : .neutral
    }

    /// Standing-by pane: green while a cue is armed.
    /// `TransportController.standingByCue` already reports `nil` for BOTH
    /// "nothing queued" and "past end of show" (see
    /// `TransportController.isPlayheadPastEnd`), so a single boolean covers
    /// both idle cases the D23 spec calls out ("nothing standing by / past
    /// end → neutral") without needing a second parameter.
    static func standingBy(hasStandingByCue: Bool) -> StageDisplayTally {
        hasStandingByCue ? .standby : .neutral
    }
}

extension StageDisplayTally {
    var borderColor: Color {
        switch self {
        case .live: return Theme.panic
        case .standby: return Theme.standby
        case .neutral: return StageDisplayChrome.neutralBorder
        }
    }

    var borderWidth: CGFloat {
        self == .neutral ? 1 : 2
    }

    var borderColorCG: CGColor {
        switch self {
        case .live: return Theme.panic.cgColor ?? StageDisplayChrome.neutralBorderCG
        case .standby: return Theme.standby.cgColor ?? StageDisplayChrome.neutralBorderCG
        case .neutral: return StageDisplayChrome.neutralBorderCG
        }
    }
}

/// The bottom-center label bar every multiview tile carries — a black
/// (85% opacity) strip, uppercase mono-feel text, letter-spaced, exactly
/// like a camera label in a broadcast multiviewer. Shared by every
/// SwiftUI-rendered pane via `MultiviewTile`; a program pane's label is the
/// AppKit/CALayer twin painted by `StageDisplayController.ProgramOverlay`
/// instead (see the type doc above).
struct MultiviewLabelBar: View {
    let text: String
    let barHeight: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Text(text.uppercased())
            .font(StageDisplayTypography.label(fontSize))
            .tracking(1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(StageDisplayChrome.labelText)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
            .background(StageDisplayChrome.labelBackground)
    }
}

/// Wraps a pane's content in the multiview tile chrome — near-black
/// background, a thin tally-colored border, a tiny corner radius — and
/// overlays the bottom-center label bar. Applied to every SwiftUI-rendered
/// stage-display pane (everything except a program pane's LIVE mirrored
/// content, which lives in a raw CALayer outside this view's own tree —
/// see `StageDisplayChrome`'s type doc).
///
/// D24: the content closure receives the INSET content size — the full
/// tile size minus the label strip's own height plus a small gap — instead
/// of the raw tile size every pane used to size itself against. Before
/// this, a pane's content was simply centered over the FULL tile (the
/// label bar painted on top via `.overlay`), so anything tall enough (the
/// standing-by pane's cue name wrapping to two lines was the reported
/// case) rendered UNDER the label strip instead of stopping short of it.
/// Every pane now lays out inside `contentSize` instead of the `size` this
/// tile itself was given, so the fix applies generally — every pane, every
/// size — rather than pane-by-pane.
struct MultiviewTile<Content: View>: View {
    let label: String
    let tally: StageDisplayTally
    let size: CGSize
    let content: (CGSize) -> Content

    init(label: String, tally: StageDisplayTally = .neutral, size: CGSize, @ViewBuilder content: @escaping (CGSize) -> Content) {
        self.label = label
        self.tally = tally
        self.size = size
        self.content = content
    }

    private var barHeight: CGFloat { max(14, size.height * 0.09) }
    private var fontSize: CGFloat { max(9, min(13, barHeight * 0.5)) }
    /// A small breathing gap between the content area and the label strip,
    /// on top of the strip's own height — keeps content from ever rendering
    /// flush against the label text, not just short of overlapping it.
    private var contentGap: CGFloat { max(2, size.height * 0.02) }
    private var contentSize: CGSize {
        CGSize(width: size.width, height: max(0, size.height - barHeight - contentGap))
    }

    var body: some View {
        ZStack(alignment: .top) {
            StageDisplayChrome.tileBackground
            content(contentSize)
                .frame(width: contentSize.width, height: contentSize.height)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) {
            MultiviewLabelBar(text: label, barHeight: barHeight, fontSize: fontSize)
        }
        .clipShape(RoundedRectangle(cornerRadius: StageDisplayChrome.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StageDisplayChrome.cornerRadius, style: .continuous)
                .stroke(tally.borderColor, lineWidth: tally.borderWidth)
        )
    }
}
