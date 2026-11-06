import CoreText
import HerdrKit
import SwiftUI
import UIKit

/// Draws a `ScreenFrame` cell by cell and turns touches and keys into terminal input.
final class TerminalCanvasView: UIView, UIKeyInput {
    var model: TerminalScreenModel? {
        didSet {
            guard model !== oldValue else { return }
            // A new model (after a reconnect) needs the grid size to attach.
            lastGrid = nil
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    var screen: ScreenFrame = .empty {
        didSet {
            // What shows before (and around) the drawn cells: the screen's own background.
            if screen.background != oldValue.background { backgroundColor = UIColor(screen.background) }
            invalidate(from: oldValue)
        }
    }
    var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            fonts = Fonts(size: fontSize, family: fontFamily)
            // At once: until the new grid reaches the emulator, the old columns don't fit the
            // new font and `geometry()` would shrink it back, which looks like a jump.
            reportGridSize(force: true, immediately: true)
            setNeedsDisplay()
        }
    }
    var fontFamily: TerminalFont = .jetBrainsMono {
        didSet {
            guard fontFamily != oldValue else { return }
            fonts = Fonts(size: fontSize, family: fontFamily)
            scaledFonts = nil
            reportGridSize(force: true, immediately: true)
            setNeedsDisplay()
        }
    }
    /// Cells that fit at the current font size; reported when they change.
    var onGridSize: ((Int, Int) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?

    private var fonts = Fonts(size: 13)
    /// Smaller fonts for when another viewer's larger size must fit; rebuilt only when the scale changes.
    private var scaledFonts: Fonts?
    /// Where a long-press landed, until a drag makes it the selection's start: Ghostty then keeps
    /// that on its text as the screen scrolls, which a viewport cell wouldn't.
    private var selectionAnchor: (x: Int, y: Int)?
    /// Runs during a long-press, to scroll while a selection drag is held against an edge.
    private var selectionScroller: CADisplayLink?
    private var selectionDragPoint: CGPoint = .zero
    private var selectionPressY: CGFloat = 0
    /// Whether the finger has moved up or down since the press. Until then it's only selecting
    /// a word that happens to be near an edge, or dragging along its line, and nothing scrolls.
    private var selectionScrollArmed = false
    /// The part of a line not scrolled yet.
    private var selectionScrollRemainder: CGFloat = 0
    /// The link a tap landed on, for the edit menu.
    private var menuLink: URL?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var lastGrid: (cols: Int, rows: Int)?
    private var scrollRemainder: CGFloat = 0
    private var pinchStartSize: CGFloat = 13
    /// While pinching, the screen as it was, scaled; nothing is re-laid-out until the fingers lift.
    private var pinchSnapshot: UIView?
    private var pinchSize: CGFloat = 13
    private var pinching = false
    /// Whether the screen was live (not scrolled back) when the current pan began.
    private var panStartedLive = true
    private lazy var pinchLabel: UILabel = {
        let label = PaddedLabel()
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.textAlignment = .center
        return label
    }()
    private let ticks = UISelectionFeedbackGenerator()
    private var pan: UIPanGestureRecognizer?
    private var pinch: UIPinchGestureRecognizer?
    /// Off while watching: the screen is shrunk to the other viewer's size, so a new font
    /// size would change nothing visible.
    var pinchEnabled = true {
        didSet { pinch?.isEnabled = pinchEnabled }
    }
    /// Watching: the terminal's size is another viewer's. It's fitted to the view as a whole
    /// (larger or smaller than our font) and outlined, or the screen would seem to end where
    /// the output does.
    var watching = false {
        didSet { if watching != oldValue { setNeedsDisplay() } }
    }
    /// For a quick look (the list's long-press preview): the font as set, never shrunk to fit;
    /// what doesn't fit is cut off on the right and above the cursor row.
    var cropped = false {
        didSet { if cropped != oldValue { setNeedsDisplay() } }
    }
    /// A sideways swipe that starts in our left part, for showing or hiding the lists beside us
    /// (see `onEdgeSwipe`). Not a `UIScreenEdgePanGestureRecognizer`: with the lists showing, our
    /// left edge is the column border, not the screen's, and a thin strip there was hard to hit.
    private lazy var edgeSwipe: UIPanGestureRecognizer = {
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = self
        swipe.isEnabled = false
        return swipe
    }()
    /// How far from our left edge an edge swipe may start: the left third. Sideways swipes do
    /// nothing else here (scrolling is vertical), but the rest stays free for other gestures.
    private var edgeWidth: CGFloat { bounds.width / 3 }
    /// Where the current touch went down, to tell whether it started at the edge.
    private var edgeTouchStart: CGPoint?
    /// Whether the current edge swipe has called `onEdgeSwipe` already.
    private var edgeSwipeFired = false
    /// Set while a swipe from the left edge should do something: called with `true` for a swipe
    /// to the right, `false` for one to the left. The edge then isn't used for scrolling.
    var onEdgeSwipe: ((_ toRight: Bool) -> Void)? {
        didSet { edgeSwipe.isEnabled = onEdgeSwipe != nil }
    }
    static let fontRange: ClosedRange<CGFloat> = 7...28
    static let padding: CGFloat = 10
    private var padding: CGFloat { Self.padding }
    /// How much of our bottom the keyboard (and key bar) covers. We handle the keyboard
    /// ourselves instead of letting SwiftUI animate our frame: an animated frame made the
    /// screen slide down and back up every time the keyboard opened or closed.
    private var keyboardInset: CGFloat = 0

    /// The area cells may use: inside the padding, above the keyboard.
    private var usableRect: CGRect {
        var rect = bounds.insetBy(dx: padding, dy: padding)
        rect.size.height = max(rect.height - keyboardInset, 0)
        return rect
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        // Never scale the drawn screen: when the keyboard or a fold animates our frame,
        // Core Animation would stretch the old bitmap to the new size until the redraw
        // lands, which looks like the font jumping. Pin it to the top-left and clip.
        contentMode = .topLeft
        layer.contentsGravity = .topLeft
        clipsToBounds = true
        backgroundColor = UIColor(screen.background)
        // For UI tests and VoiceOver users: the terminal as one element.
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityIdentifier = "terminal-screen"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        self.pinch = pinch
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        self.pan = pan
        addGestureRecognizer(edgeSwipe)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)
        addInteraction(editMenu)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The keyboard's final frame is known when its animation starts: apply it at once,
    /// without animation, and send the final size straight away (no need to wait for it to settle).
    @objc private func keyboardWillChange(_ note: Notification) {
        var inset: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification,
           let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           let window
        {
            // The keyboard frame is in screen coordinates; how much of us does it cover?
            let keyboard = convert(window.convert(end, from: window.screen.coordinateSpace), from: window)
            inset = max(0, bounds.intersection(keyboard).height)
        }
        guard inset != keyboardInset else { return }
        keyboardInset = inset
        setNeedsDisplay()
        reportGridSize(force: false, immediately: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        reportGridSize(force: false)
        setNeedsDisplay()
    }

    private var pendingGridReport: DispatchWorkItem?

    /// Reports how many cells fit. The first report goes out at once (to attach);
    /// later ones wait until the size settles, so a keyboard or fold animation
    /// sends one resize instead of one per frame (each makes the program redraw).
    private func reportGridSize(force: Bool, immediately: Bool = false) {
        let usable = usableRect
        guard usable.width > 0, usable.height > 0 else { return }
        let cols = max(Int(usable.width / fonts.cellWidth), 10)
        let rows = max(Int(usable.height / fonts.cellHeight), 3)
        guard force || lastGrid.map({ $0.cols != cols || $0.rows != rows }) ?? true else { return }
        let first = lastGrid == nil
        lastGrid = (cols, rows)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        model?.cellPixels = (Int((fonts.cellWidth * scale).rounded()), Int((fonts.cellHeight * scale).rounded()))
        pendingGridReport?.cancel()
        if first || immediately {
            onGridSize?(cols, rows)
            return
        }
        let report = DispatchWorkItem { [weak self] in
            guard let self, let grid = self.lastGrid else { return }
            self.onGridSize?(grid.cols, grid.rows)
        }
        pendingGridReport = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: report)
    }

    // MARK: Drawing

    private struct Geometry {
        var origin: CGPoint
        var fonts: Fonts
        var cellWidth: CGFloat { fonts.cellWidth }
        var cellHeight: CGFloat { fonts.cellHeight }
    }

    /// Where cells go.
    ///
    /// Too wide (another viewer sets more columns): shrink the font to fit. Too tall
    /// (the keyboard just came up and our resize hasn't landed yet): keep the font,
    /// and shift up only as far as needed to keep the cursor row in view. Changing the
    /// font for a height change made the screen jump while the keyboard animated.
    /// Watching, the whole terminal fits instead: shrunk, or enlarged up to the largest font.
    private func geometry() -> Geometry {
        let usable = usableRect
        var origin = CGPoint(x: padding, y: padding)
        guard screen.cols > 0, screen.rows > 0, usable.width > 0, usable.height > 0 else {
            return Geometry(origin: origin, fonts: fonts)
        }
        var drawFonts = fonts
        var scale = usable.width / (CGFloat(screen.cols) * fonts.cellWidth)
        if watching {
            scale = min(scale, usable.height / (CGFloat(screen.rows) * fonts.cellHeight), Self.fontRange.upperBound / fontSize)
        }
        if cropped {
            scale = 1
        }
        if scale < 1 || (watching && scale > 1) {
            let size = (fontSize * scale * 4).rounded(.down) / 4
            if scaledFonts?.size != size { scaledFonts = Fonts(size: size, family: fontFamily) }
            drawFonts = scaledFonts!
        }
        let visibleRows = Int(usable.height / drawFonts.cellHeight)
        // The cursor's row even when hidden (spinners, coding agents).
        if screen.rows > visibleRows, let row = screen.cursor?.y ?? screen.cursorRow, row >= visibleRows {
            origin.y -= CGFloat(row - visibleRows + 1) * drawFonts.cellHeight
        }
        return Geometry(origin: origin, fonts: drawFonts)
    }

    /// The cell under a point, clamped to the screen.
    private func cell(at point: CGPoint) -> (x: Int, y: Int) {
        let g = geometry()
        let x = Int((point.x - g.origin.x) / g.cellWidth)
        let y = Int((point.y - g.origin.y) / g.cellHeight)
        return (min(max(x, 0), max(screen.cols - 1, 0)), min(max(y, 0), max(screen.rows - 1, 0)))
    }

    private func lineRect(_ y: Int, _ g: Geometry) -> CGRect {
        CGRect(x: 0, y: g.origin.y + CGFloat(y) * g.cellHeight, width: bounds.width, height: g.cellHeight)
            .insetBy(dx: 0, dy: -1)
    }

    /// Redraws only lines whose cells, selection or cursor changed.
    private func invalidate(from old: ScreenFrame) {
        guard old.cols == screen.cols, old.rows == screen.rows, old.lines.count == screen.lines.count,
              old.background == screen.background, old.foreground == screen.foreground
        else {
            setNeedsDisplay()
            return
        }
        let g = geometry()
        for y in screen.lines.indices
        where old.lines[y] != screen.lines[y]
            || (old.selection.indices.contains(y) ? old.selection[y] : nil)
                != (screen.selection.indices.contains(y) ? screen.selection[y] : nil)
        {
            setNeedsDisplay(lineRect(y, g))
        }
        if old.scrollbar != screen.scrollbar, scrollbarThumb(old.scrollbar) != nil || scrollbarThumb(screen.scrollbar) != nil {
            setNeedsDisplay(CGRect(x: bounds.maxX - 12, y: 0, width: 12, height: bounds.height))
        }
        if old.cursor != screen.cursor {
            if let y = old.cursor?.y { setNeedsDisplay(lineRect(y, g)) }
            if let y = screen.cursor?.y { setNeedsDisplay(lineRect(y, g)) }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor(screen.background).setFill()
        context.fill(rect)
        // While pinching, the scaled snapshot shows the screen; drawing under it would show at its edges.
        guard pinchSnapshot == nil, screen.cols > 0, !screen.lines.isEmpty else { return }

        let g = geometry()
        let highlight = UIColor.tintColor.withAlphaComponent(0.4)
        for (y, line) in screen.lines.enumerated() {
            let top = g.origin.y + CGFloat(y) * g.cellHeight
            guard top < rect.maxY, top + g.cellHeight > rect.minY else { continue }
            drawBackgrounds(line, top: top, origin: g.origin, cellWidth: g.cellWidth, cellHeight: g.cellHeight, in: context)
            if y < screen.selection.count, let selected = screen.selection[y] {
                highlight.setFill()
                context.fill(CGRect(
                    x: g.origin.x + CGFloat(selected.lowerBound) * g.cellWidth, y: top,
                    width: CGFloat(selected.count) * g.cellWidth, height: g.cellHeight))
            }
            drawText(line, top: top, origin: g.origin, cellWidth: g.cellWidth, cellHeight: g.cellHeight, fonts: g.fonts)
        }
        if let cursor = screen.cursor, cursor.y < screen.lines.count {
            drawCursor(cursor, origin: g.origin, cellWidth: g.cellWidth, cellHeight: g.cellHeight, fonts: g.fonts, in: context)
        }
        if watching {
            let cells = CGRect(
                x: g.origin.x, y: g.origin.y,
                width: CGFloat(screen.cols) * g.cellWidth, height: CGFloat(screen.lines.count) * g.cellHeight)
            UIColor(screen.foreground).withAlphaComponent(0.3).setStroke()
            let outline = UIBezierPath(roundedRect: cells.insetBy(dx: -3, dy: -3), cornerRadius: 4)
            outline.lineWidth = 1
            outline.stroke()
        }
        if let thumb = scrollbarThumb(screen.scrollbar) {
            UIColor(screen.foreground).withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: thumb, cornerRadius: thumb.width / 2).fill()
        }
    }

    /// Shown only while scrolled back; the live bottom needs no indicator.
    private func scrollbarThumb(_ bar: Scrollbar?) -> CGRect? {
        guard let bar, !bar.atBottom, bar.total > bar.visible, bar.total > 0 else { return nil }
        // Above the keyboard, like the cells.
        let track = CGRect(x: 0, y: 4, width: bounds.width, height: max(bounds.height - keyboardInset - 8, 0))
        let height = max(track.height * CGFloat(bar.visible) / CGFloat(bar.total), 28)
        let progress = CGFloat(bar.offset) / CGFloat(bar.total - bar.visible)
        return CGRect(x: bounds.maxX - 6, y: track.minY + (track.height - height) * progress, width: 4, height: height)
    }

    private func colors(_ style: CellStyle) -> (fg: RGB, bg: RGB?) {
        var fg = style.foreground ?? screen.foreground
        var bg = style.background
        if style.inverse {
            let oldBg = bg ?? screen.background
            bg = fg
            fg = oldBg
        }
        return (fg, bg)
    }

    private func drawBackgrounds(
        _ line: [ScreenCell], top: CGFloat, origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat,
        in context: CGContext
    ) {
        var x = 0
        while x < line.count {
            guard let bg = colors(line[x].style).bg else {
                x += 1
                continue
            }
            var end = x + 1
            while end < line.count, colors(line[end].style).bg == bg { end += 1 }
            UIColor(bg).setFill()
            context.fill(CGRect(
                x: origin.x + CGFloat(x) * cellWidth, y: top,
                width: CGFloat(end - x) * cellWidth, height: cellHeight))
            x = end
        }
    }

    /// Groups plain single-width cells of one style into runs; wide or complex
    /// graphemes are drawn on their own so the grid stays aligned.
    private func drawText(
        _ line: [ScreenCell], top: CGFloat, origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, fonts: Fonts
    ) {
        var linked = IndexSet()
        for link in LinkDetector.links(in: line) { linked.insert(integersIn: link.columns) }
        for (column, cell) in line.enumerated() where cell.hyperlink { linked.insert(column) }
        var x = 0
        while x < line.count {
            let cell = line[x]
            if cell.width == 0 || cell.text.isEmpty || cell.text == " " || cell.style.invisible {
                x += 1
                continue
            }
            let simple = cell.width == 1 && cell.text.unicodeScalars.count == 1 && cell.text.unicodeScalars.first!.isASCII
            var text = cell.text
            var end = x + 1
            if simple {
                while end < line.count {
                    let next = line[end]
                    guard next.style == cell.style, next.width == 1, linked.contains(end) == linked.contains(x) else {
                        break
                    }
                    if next.text.isEmpty {
                        text += " "
                    } else if next.text.unicodeScalars.count == 1, next.text.unicodeScalars.first!.isASCII {
                        text += next.text
                    } else {
                        break
                    }
                    end += 1
                }
            }
            if !simple, cell.width == 1, cell.text.unicodeScalars.count == 1,
               let dots = Self.braille(cell.text.unicodeScalars.first!)
            {
                let box = CGRect(x: origin.x + CGFloat(x) * cellWidth, y: top, width: cellWidth, height: cellHeight)
                drawBraille(dots, in: box, style: cell.style)
                x = end
                continue
            }
            // One cell wide but emoji-capable (Claude Code's ⏺, ⏸, ☑…): ask for the text form, or
            // iOS falls back to Apple Color Emoji for glyphs the terminal font lacks.
            if !simple, cell.width == 1, let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1,
               scalar.properties.isEmoji, !scalar.isASCII
            {
                text.unicodeScalars.append("\u{FE0E}")
            }
            var style = cell.style
            if linked.contains(x) { style.underline = true }
            NSAttributedString(string: text, attributes: attributes(style, fonts: fonts))
                .draw(at: CGPoint(x: origin.x + CGFloat(x) * cellWidth, y: top))
            x = end
        }
    }

    /// The dots of a braille pattern (U+2800–U+28FF), nil for anything else.
    private static func braille(_ scalar: Unicode.Scalar) -> UInt8? {
        (0x2800...0x28FF).contains(scalar.value) ? UInt8(scalar.value - 0x2800) : nil
    }

    /// Braille spread over the whole cell, as Ghostty draws it: from the font, the dots sit in
    /// the glyph's box, and graphs (btop) show gaps between rows and columns.
    private func drawBraille(_ dots: UInt8, in box: CGRect, style: CellStyle) {
        guard dots != 0, let context = UIGraphicsGetCurrentContext() else { return }
        var color = UIColor(colors(style).fg)
        if style.faint { color = color.withAlphaComponent(0.6) }
        color.setFill()
        // Bits 0–2 and 6 are the left column top to bottom, 3–5 and 7 the right one.
        let positions: [(column: Int, row: Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        let spacingX = box.width / 2, spacingY = box.height / 4
        let size = max(min(spacingX, spacingY) * 0.6, 1)
        for (bit, position) in positions.enumerated() where dots & (1 << bit) != 0 {
            let center = CGPoint(
                x: box.minX + (CGFloat(position.column) + 0.5) * spacingX,
                y: box.minY + (CGFloat(position.row) + 0.5) * spacingY)
            context.fill(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        }
    }

    private func attributes(_ style: CellStyle, fonts: Fonts, color: RGB? = nil) -> [NSAttributedString.Key: Any] {
        var fg = UIColor(color ?? colors(style).fg)
        if style.faint { fg = fg.withAlphaComponent(0.6) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.font(bold: style.bold, italic: style.italic),
            .foregroundColor: fg,
        ]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private func drawCursor(
        _ cursor: ScreenCursor, origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, fonts: Fonts,
        in context: CGContext
    ) {
        let cell = cursor.x < screen.lines[cursor.y].count ? screen.lines[cursor.y][cursor.x] : nil
        let width = CGFloat(max(Int(cell?.width ?? 1), 1)) * cellWidth
        let box = CGRect(
            x: origin.x + CGFloat(cursor.x) * cellWidth, y: origin.y + CGFloat(cursor.y) * cellHeight,
            width: width, height: cellHeight)
        let color = UIColor(screen.cursorColor ?? screen.foreground)
        color.setFill()
        color.setStroke()
        let focused = isFirstResponder
        switch cursor.shape {
        case .bar: context.fill(CGRect(x: box.minX, y: box.minY, width: 2, height: box.height))
        case .underline: context.fill(CGRect(x: box.minX, y: box.maxY - 2, width: box.width, height: 2))
        case .hollowBlock: context.stroke(box.insetBy(dx: 0.5, dy: 0.5), width: 1)
        case .block:
            guard focused else {
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5), width: 1)
                return
            }
            context.fill(box)
            if let cell, !cell.text.isEmpty {
                NSAttributedString(
                    string: cell.text, attributes: attributes(cell.style, fonts: fonts, color: screen.background)
                ).draw(at: box.origin)
            }
        }
    }

    // MARK: Gestures

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let model else { return }
        let point = tap.location(in: self)
        editMenu.dismissMenu()
        switch model.tap(at: cell(at: point)) {
        case .link(let url):
            menuLink = url
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        case .unhandled:
            if !isFirstResponder { _ = becomeFirstResponder() }
        case .handled:
            break
        }
    }

    /// Long-press selects a word; keep dragging to extend, against the top or bottom edge to
    /// scroll on; let go for Copy.
    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        guard let model else { return }
        let point = press.location(in: self)
        switch press.state {
        case .began:
            let at = cell(at: point)
            selectionAnchor = at
            model.selectWord(at: at)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            startSelectionScroller(at: point)
        case .changed:
            selectionDragPoint = point
            if abs(point.y - selectionPressY) >= 16 { selectionScrollArmed = true }
            extendSelection(to: point)
        case .ended:
            stopSelectionScroller()
            selectionAnchor = nil
            menuLink = nil
            if model.hasSelection {
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        default:
            stopSelectionScroller()
            selectionAnchor = nil
        }
    }

    /// Moves the selection's end under the finger, after scrolling by `lines`.
    private func extendSelection(to point: CGPoint, scrolling lines: Int = 0) {
        guard let model else { return }
        let at = cell(at: point)
        if let anchor = selectionAnchor {
            // Still the word from the press, until the finger leaves its cell or the screen moves.
            guard at != anchor || lines != 0 else { return }
            selectionAnchor = nil
            model.select(from: anchor, to: at)
        }
        model.extendSelection(to: at, scrolling: lines)
    }

    private func startSelectionScroller(at point: CGPoint) {
        selectionDragPoint = point
        selectionPressY = point.y
        selectionScrollArmed = false
        selectionScrollRemainder = 0
        let scroller = CADisplayLink(target: self, selector: #selector(selectionScrollerFired(_:)))
        scroller.add(to: .main, forMode: .common)
        selectionScroller = scroller
    }

    private func stopSelectionScroller() {
        selectionScroller?.invalidate()
        selectionScroller = nil
    }

    /// Fires on every frame of a long-press: the finger may be holding still at the edge, when
    /// the gesture reports nothing.
    @objc private func selectionScrollerFired(_ scroller: CADisplayLink) {
        guard window != nil else { return stopSelectionScroller() }
        let speed = selectionScrollSpeed(at: selectionDragPoint.y)
        guard speed != 0 else {
            selectionScrollRemainder = 0
            return
        }
        selectionScrollRemainder += speed * CGFloat(scroller.targetTimestamp - scroller.timestamp)
        let lines = Int(selectionScrollRemainder)
        guard lines != 0 else { return }
        selectionScrollRemainder -= CGFloat(lines)
        extendSelection(to: selectionDragPoint, scrolling: lines)
    }

    /// How fast a selection drag at this height scrolls, in lines per second (negative is up):
    /// not at all away from the top and bottom edges, then faster the closer it gets. Also not at
    /// all with no history that way, as on the alternate screen, which has none.
    private func selectionScrollSpeed(at y: CGFloat) -> CGFloat {
        guard selectionScrollArmed, let bar = screen.scrollbar else { return 0 }
        let g = geometry()
        let usable = usableRect
        let top = max(g.origin.y, usable.minY)
        let bottom = min(g.origin.y + CGFloat(screen.rows) * g.cellHeight, usable.maxY)
        // A fingertip's worth, but never so much of a short screen that nothing is left to drag in.
        let zone = min(max(g.cellHeight * 2, 44), (bottom - top) / 4)
        guard zone > 0 else { return 0 }
        func speed(depth: CGFloat) -> CGFloat {
            let depth = min(depth, 1)
            return 4 + 36 * depth * depth
        }
        let intoTop = (top + zone - y) / zone
        let intoBottom = (y - (bottom - zone)) / zone
        if intoTop > 0, bar.offset > 0 { return -speed(depth: intoTop) }
        if intoBottom > 0, !bar.atBottom { return speed(depth: intoBottom) }
        return 0
    }

    /// Zooms in two steps, so pinching stays smooth: while the fingers move, only a snapshot of
    /// the screen scales (no new fonts, no redraw, no resize, no reflow of the scrollback); when
    /// they lift, the font changes once and one resize goes out.
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinching = true
            pinchStartSize = fontSize
            pinchSize = fontSize
            // A pinch often starts as a one-finger pan: undo the scrolling it did, and stop it.
            if let pan, pan.state == .began || pan.state == .changed {
                if panStartedLive { model?.scroll(toBottom: true) }
                pan.isEnabled = false
                pan.isEnabled = true
            }
            addSubview(pinchLabel)
            ticks.prepare()
            updatePinch(size: fontSize)
            guard let snapshot = snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = bounds
            // Scale from where text starts, so the snapshot lines up with the result.
            snapshot.layer.anchorPoint = CGPoint(x: padding / max(bounds.width, 1), y: padding / max(bounds.height, 1))
            snapshot.layer.position = CGPoint(x: padding, y: padding)
            insertSubview(snapshot, belowSubview: pinchLabel)
            pinchSnapshot = snapshot
            setNeedsDisplay()
        case .changed:
            guard pinching else { return }
            let raw = pinchStartSize * pinch.scale
            let size = min(max(raw, Self.fontRange.lowerBound), Self.fontRange.upperBound)
            pinchSnapshot?.transform = CGAffineTransform(scaleX: size / pinchStartSize, y: size / pinchStartSize)
            let step = (size * 2).rounded() / 2
            if step != pinchSize {
                if step.rounded() == step || step == Self.fontRange.lowerBound || step == Self.fontRange.upperBound {
                    ticks.selectionChanged()
                }
                updatePinch(size: step)
            }
        case .ended:
            finishPinch(apply: true)
        default:
            finishPinch(apply: false)
        }
    }

    /// The size the pinch would land on, and how many cells that gives.
    private func updatePinch(size: CGFloat) {
        pinchSize = size
        let preview = Fonts(size: size, family: fontFamily)
        let usable = usableRect
        let cols = max(Int(usable.width / preview.cellWidth), 10)
        let rows = max(Int(usable.height / preview.cellHeight), 3)
        let pointText = size.rounded() == size ? "\(Int(size))" : String(format: "%.1f", size)
        pinchLabel.text = "\(pointText) pt · \(cols) × \(rows)"
        pinchLabel.sizeToFit()
        pinchLabel.center = CGPoint(x: bounds.midX, y: usable.minY + 40)
    }

    private func finishPinch(apply: Bool) {
        guard pinching else { return }
        pinching = false
        let snapshot = pinchSnapshot
        pinchSnapshot = nil
        pinchLabel.removeFromSuperview()
        if apply, pinchSize != fontSize {
            fontSize = pinchSize
            onFontSize?(pinchSize)
        }
        setNeedsDisplay()
        guard let snapshot else { return }
        // Let the real screen draw underneath, then fade the snapshot away.
        UIView.animate(withDuration: 0.18, delay: 0.05, options: [.curveEaseOut]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    /// Fires once the finger has come far enough in, so the sidebar follows the swipe.
    @objc private func edgeSwiped(_ swipe: UIPanGestureRecognizer) {
        switch swipe.state {
        case .began:
            edgeSwipeFired = false
        case .changed, .ended:
            let x = swipe.translation(in: self).x
            let flick = swipe.state == .ended ? swipe.velocity(in: self).x : 0
            if !edgeSwipeFired, abs(x) > 40 || abs(flick) > 300 {
                edgeSwipeFired = true
                onEdgeSwipe?(abs(x) > 40 ? x > 0 : flick > 0)
            }
        default:
            break
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let model else { return }
        if pan.state == .began {
            scrollRemainder = 0
            panStartedLive = !model.scrolledBack
        }
        let cellHeight = geometry().cellHeight
        let dy = pan.translation(in: self).y + scrollRemainder
        let lines = Int(dy / cellHeight)
        if lines != 0 {
            // Finger down moves the content down: that is scrolling up (back).
            let at = cell(at: pan.location(in: self))
            model.scroll(lines: -lines, column: at.x, row: at.y)
            scrollRemainder = dy - CGFloat(lines) * cellHeight
            pan.setTranslation(.zero, in: self)
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            model?.wantsKeyboard = true
            model?.focusChanged(true)
            setNeedsDisplay()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            model?.wantsKeyboard = false
            model?.focusChanged(false)
            setNeedsDisplay()
        }
        return resigned
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        model?.type(text)
    }

    func deleteBackward() {
        model?.press(.backspace)
    }

    // No autocorrect, capitals or smart punctuation in a terminal.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    /// Follows the terminal theme's brightness.
    var darkKeyboard = true {
        didSet {
            guard darkKeyboard != oldValue else { return }
            if isFirstResponder { reloadInputViews() }
        }
    }
    var keyboardAppearance: UIKeyboardAppearance { get { darkKeyboard ? .dark : .light } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }

    private lazy var keyBar = KeyBar(target: self)
    override var inputAccessoryView: UIView? { keyBar }

    /// Hardware keyboard: special keys and Ctrl/Alt combinations go through the encoder;
    /// plain typing falls through to `insertText`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let model, handle(key, model: model) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func handle(_ key: UIKey, model: TerminalScreenModel) -> Bool {
        var modifiers: KeyModifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        // Command shortcuts belong to iOS (paste, app switching).
        if key.modifierFlags.contains(.command) { return false }

        if let special = Self.specialKeys[key.keyCode] {
            model.press(special, modifiers: modifiers)
            return true
        }
        if modifiers.contains(.control) || modifiers.contains(.alt) {
            let base = key.charactersIgnoringModifiers
            if base.count == 1, let c = base.first {
                if c.isLetter {
                    model.press(.letter(c), modifiers: modifiers, text: modifiers.contains(.alt) ? base : nil)
                    return true
                }
                if let digit = c.wholeNumberValue {
                    model.press(.digit(digit), modifiers: modifiers)
                    return true
                }
            }
        }
        return false
    }

    private static let specialKeys: [UIKeyboardHIDUsage: TerminalKey] = {
        var keys: [UIKeyboardHIDUsage: TerminalKey] = [
            .keyboardReturnOrEnter: .enter, .keypadEnter: .enter, .keyboardTab: .tab,
            .keyboardDeleteOrBackspace: .backspace, .keyboardEscape: .escape,
            .keyboardDeleteForward: .delete, .keyboardInsert: .insert,
            .keyboardUpArrow: .up, .keyboardDownArrow: .down,
            .keyboardLeftArrow: .left, .keyboardRightArrow: .right,
            .keyboardHome: .home, .keyboardEnd: .end,
            .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown,
        ]
        let functionKeys: [UIKeyboardHIDUsage] = [
            .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
            .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
        ]
        for (index, usage) in functionKeys.enumerated() { keys[usage] = .function(index + 1) }
        return keys
    }()

    // MARK: Paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        case #selector(copy(_:)): model?.hasSelection ?? false
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) {
        model?.copySelection()
        model?.clearSelection()
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { model?.paste(text) }
    }

    // Key bar actions.
    func keyBarPressed(_ key: TerminalKey, modifiers: KeyModifiers = []) {
        model?.press(key, modifiers: modifiers)
    }

    func keyBarToggleControl() {
        model?.controlLatched.toggle()
        keyBar.controlOn = model?.controlLatched ?? false
    }

    func refreshKeyBar() {
        keyBar.controlOn = model?.controlLatched ?? false
    }
}

extension TerminalCanvasView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if let url = menuLink {
            menuLink = nil
            var actions: [UIMenuElement] = []
            if ["http", "https"].contains(url.scheme?.lowercased()) {
                actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                })
            }
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = url
            })
            return UIMenu(title: url.absoluteString, children: actions)
        }
        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.model?.copySelection()
                self?.model?.clearSelection()
            },
        ]
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.model?.clearSelection()
                if let text = UIPasteboard.general.string { self?.model?.paste(text) }
            })
        }
        return UIMenu(children: actions)
    }
}

/// The terminal fonts to choose from in Settings.
enum TerminalFont: String, CaseIterable, Identifiable {
    /// Bundled in `hirte/Fonts` (SIL OFL 1.1).
    case jetBrainsMono
    /// The system's monospaced font.
    case sfMono
    case menlo
    /// Bundled (MIT); regular and bold only, so italic text shows upright.
    case comicMono

    var id: Self { self }

    var title: String {
        switch self {
        case .jetBrainsMono: "JetBrains Mono"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .comicMono: "Comic Mono"
        }
    }

    /// PostScript names: regular, bold, italic, bold italic. Nil: the system font.
    fileprivate var names: [String?] {
        switch self {
        case .jetBrainsMono: ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"]
        case .sfMono: [nil, nil, nil, nil]
        case .menlo: ["Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"]
        case .comicMono: ["ComicMono", "ComicMono-Bold", nil, nil]
        }
    }

    static let storageKey = "terminal.font"
    static let sizeKey = "terminal.fontSize"
    static let defaultSize = 13.0
}

/// Monospaced fonts and the cell size they imply.
struct Fonts {
    let size: CGFloat
    let family: TerminalFont
    let regular: UIFont
    let bold: UIFont
    let italic: UIFont
    let boldItalic: UIFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    init(size: CGFloat, family: TerminalFont = .jetBrainsMono) {
        self.size = size
        self.family = family
        let names = family.names
        regular = names[0].flatMap { Self.mono($0, size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        bold = names[1].flatMap { Self.mono($0, size) } ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        func italicized(_ font: UIFont) -> UIFont {
            font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic))
                .map { UIFont(descriptor: $0, size: size) } ?? font
        }
        italic = names[2].flatMap { Self.mono($0, size) } ?? italicized(regular)
        boldItalic = names[3].flatMap { Self.mono($0, size) } ?? italicized(bold)
        cellWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
        cellHeight = ceil(regular.lineHeight)
    }

    /// A named font (registering the bundled ones first); nil if it isn't available.
    static func mono(_ name: String, _ size: CGFloat) -> UIFont? {
        _ = registered
        return UIFont(name: name, size: size)
    }

    /// Registers the bundled fonts once, without listing them in Info.plist.
    private static let registered: Bool = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }()

    func font(bold isBold: Bool, italic isItalic: Bool) -> UIFont {
        switch (isBold, isItalic) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }
}

extension UIColor {
    convenience init(_ rgb: RGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

/// Keys a phone keyboard lacks, shown above it.
final class KeyBar: UIInputView {
    private weak var target: TerminalCanvasView?
    private var controlButton: UIButton!

    var controlOn = false {
        didSet { controlButton.isSelected = controlOn }
    }

    init(target: TerminalCanvasView) {
        self.target = target
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 48),
        ])

        func button(_ title: String, symbol: String? = nil, label: String, action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .medium
            // Eleven keys share the width: small insets, and one line ("ctrl" must not wrap).
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
            config.titleLineBreakMode = .byClipping
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Fonts.mono("JetBrainsMono-Bold", 14) ?? .monospacedSystemFont(ofSize: 14, weight: .medium)
                return attributes
            }
            if let symbol {
                config.image = UIImage(systemName: symbol)
            } else {
                config.title = title
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            button.accessibilityLabel = label
            return button
        }

        stack.addArrangedSubview(button("esc", label: "Escape") { [weak self] in self?.target?.keyBarPressed(.escape) })
        stack.addArrangedSubview(button("tab", label: "Tab") { [weak self] in self?.target?.keyBarPressed(.tab) })
        controlButton = button("ctrl", label: "Control") { [weak self] in self?.target?.keyBarToggleControl() }
        controlButton.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseBackgroundColor = button.isSelected ? .tintColor : nil
            config?.baseForegroundColor = button.isSelected ? .white : nil
            button.configuration = config
        }
        stack.addArrangedSubview(controlButton)
        stack.addArrangedSubview(button("^C", label: "Control C") { [weak self] in
            self?.target?.keyBarPressed(.letter("c"), modifiers: .control)
        })
        for (symbol, key, label) in [
            ("arrow.left", TerminalKey.left, "Left"), ("arrow.down", .down, "Down"),
            ("arrow.up", .up, "Up"), ("arrow.right", .right, "Right"),
        ] {
            stack.addArrangedSubview(button("", symbol: symbol, label: label) { [weak self] in
                self?.target?.keyBarPressed(key)
            })
        }
        stack.addArrangedSubview(button("", symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") {
            [weak self] in _ = self?.target?.resignFirstResponder()
        })
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// SwiftUI wrapper.
struct TerminalCanvas: UIViewRepresentable {
    let model: TerminalScreenModel
    @Binding var fontSize: Double
    var fontFamily: TerminalFont = .jetBrainsMono
    var dark = true
    /// What a swipe in from the left edge does, if anything.
    var onEdgeSwipe: ((_ toRight: Bool) -> Void)?
    /// A quick look: see `TerminalCanvasView.cropped`.
    var cropped = false
    let onGridSize: (Int, Int) -> Void

    func makeUIView(context: Context) -> TerminalCanvasView {
        let view = TerminalCanvasView()
        view.model = model
        view.fontFamily = fontFamily
        view.fontSize = fontSize
        view.darkKeyboard = dark
        view.onGridSize = onGridSize
        view.onEdgeSwipe = onEdgeSwipe
        view.onFontSize = { fontSize = Double($0) }
        // The model's screen from the first frame (already in the theme's colors while attaching).
        view.screen = model.frame
        return view
    }

    func updateUIView(_ view: TerminalCanvasView, context: Context) {
        view.model = model
        view.fontFamily = fontFamily
        view.fontSize = fontSize
        view.darkKeyboard = dark
        view.onGridSize = onGridSize
        view.onEdgeSwipe = onEdgeSwipe
        view.pinchEnabled = !model.watching && !cropped
        view.watching = model.watching && !cropped
        view.cropped = cropped
        view.screen = model.frame
        view.refreshKeyBar()
        // The toolbar's keyboard button flips this; follow it once the view is on screen.
        if model.wantsKeyboard != view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async {
                if model.wantsKeyboard { _ = view.becomeFirstResponder() } else { _ = view.resignFirstResponder() }
            }
        }
    }
}

/// A label with room around its text, for the zoom indicator.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = super.sizeThatFits(size)
        return CGSize(width: fit.width + insets.left + insets.right, height: fit.height + insets.top + insets.bottom)
    }
}

extension TerminalCanvasView: UIGestureRecognizerDelegate {
    /// A pinch may start while a one-finger pan runs (the second finger lands a moment later);
    /// otherwise the pan wins and the pinch never begins. The pinch then cancels the pan.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && other === pan)
            || (gestureRecognizer === pan && other is UIPinchGestureRecognizer)
    }

    /// While the edge swipe is on, a touch at the left edge is its first; anywhere else it fails
    /// at once, and scrolling goes on as before.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === pan && other === edgeSwipe && edgeSwipe.isEnabled
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === edgeSwipe { edgeTouchStart = touch.location(in: self) }
        return true
    }

    /// An edge swipe starts in the left part and goes clearly sideways; anything else fails it at
    /// once, so scrolling begins as usual.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgeSwipe, let swipe = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = swipe.velocity(in: self)
        return (edgeTouchStart?.x ?? .infinity) <= edgeWidth && abs(velocity.x) > 1.5 * abs(velocity.y)
    }
}
