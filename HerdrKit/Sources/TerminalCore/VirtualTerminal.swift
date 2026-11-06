import Foundation
import GhosttyVt

/// A 24-bit color.
public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ c: GhosttyColorRgb) {
        self.init(r: c.r, g: c.g, b: c.b)
    }
}

public struct CellStyle: Hashable, Sendable {
    /// nil: the terminal's default foreground / background.
    public var foreground: RGB?
    public var background: RGB?
    public var bold = false
    public var italic = false
    public var faint = false
    public var underline = false
    public var strikethrough = false
    public var inverse = false
    public var invisible = false

    public static let plain = CellStyle()
}

public struct ScreenCell: Hashable, Sendable {
    /// The grapheme; empty for a blank cell or the tail of a wide character.
    public var text: String
    public var style: CellStyle
    /// 2 for wide characters (CJK, most emoji), 0 for the cell a wide character spills into.
    public var width: UInt8
    /// Part of an OSC 8 hyperlink (see `VirtualTerminal.link(at:)`).
    public var hyperlink: Bool = false
}

/// Where the viewport sits in the scrollback, in rows.
public struct Scrollbar: Hashable, Sendable {
    public var total: Int
    public var offset: Int
    public var visible: Int

    /// Showing the live bottom of the screen.
    public var atBottom: Bool { offset + visible >= total }
}

public struct ScreenCursor: Hashable, Sendable {
    public enum Shape: Sendable { case block, bar, underline, hollowBlock }
    public var x: Int
    public var y: Int
    public var shape: Shape
    public var blinking: Bool
}

/// Everything needed to draw the viewport once.
public struct ScreenFrame: Sendable {
    public var cols: Int
    public var rows: Int
    public var lines: [[ScreenCell]]
    public var cursor: ScreenCursor?
    public var foreground: RGB
    public var background: RGB
    public var cursorColor: RGB?
    /// Selected columns per line (inclusive), nil where nothing is selected.
    public var selection: [ClosedRange<Int>?] = []
    /// Lines whose content changed since the previous frame; nil means everything.
    public var changedLines: IndexSet?
    public var scrollbar: Scrollbar?
    /// The cursor's row in the viewport, also while the program hides the cursor (spinners and
    /// coding agents do): where the action is.
    public var cursorRow: Int?

    public static let empty = ScreenFrame(
        cols: 0, rows: 0, lines: [], cursor: nil,
        foreground: RGB(r: 0xdd, g: 0xdd, b: 0xdd), background: RGB(r: 0x1d, g: 0x1f, b: 0x21), cursorColor: nil)

    /// The visible text, for tests and accessibility.
    public var text: String {
        lines.map { line in
            line.map { $0.width == 0 ? "" : ($0.text.isEmpty ? " " : $0.text) }.joined()
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
}

public enum TerminalError: Error {
    case ghostty(String, Int32)
}

/// A terminal emulator (libghostty-vt): feed it program output, read the screen, encode keys.
///
/// Not thread-safe: use it from one thread or actor.
public final class VirtualTerminal {
    public private(set) var cols: Int
    public private(set) var rows: Int

    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var keyEncoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    /// Lines from the previous frame, reused when libghostty-vt says a row is clean.
    private var cachedLines: [[ScreenCell]] = []
    /// What the emulator answered (queries, mode 2048 size reports) since the last `takeReplies()`.
    private var replies = Data()
    /// A cell's size in pixels, for size reports (mode 2048, XTWINOPS); 0 when unknown.
    public var cellPixels: (width: Int, height: Int) = (0, 0)

    public init(cols: Int, rows: Int, scrollbackLines: Int = 10_000) throws {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        try check(ghostty_terminal_new(nil, &terminal, UInt16(self.cols), UInt16(self.rows)), "terminal_new")
        var lines = UInt(scrollbackLines)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // Replies go back to the program: Textual, for one, ignores SIGWINCH once mode 2048 is on
        // and only learns a new size from the in-band report.
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data else { return }
            Unmanaged<VirtualTerminal>.fromOpaque(userdata).takeUnretainedValue().replies.append(data, count: length)
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        let size: GhosttyTerminalSizeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let vt = Unmanaged<VirtualTerminal>.fromOpaque(userdata).takeUnretainedValue()
            out.pointee = GhosttySizeReportSize(
                rows: UInt16(clamping: vt.rows), columns: UInt16(clamping: vt.cols),
                cell_width: UInt32(clamping: vt.cellPixels.width), cell_height: UInt32(clamping: vt.cellPixels.height))
            return true
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
        try check(ghostty_render_state_new(nil, &renderState), "render_state_new")
        try check(ghostty_render_state_row_iterator_new(nil, &rowIterator), "row_iterator_new")
        try check(ghostty_render_state_row_cells_new(nil, &rowCells), "row_cells_new")
        try check(ghostty_key_encoder_new(nil, &keyEncoder), "key_encoder_new")
        try check(ghostty_key_event_new(nil, &keyEvent), "key_event_new")
        try check(ghostty_mouse_encoder_new(nil, &mouseEncoder), "mouse_encoder_new")
        try check(ghostty_mouse_event_new(nil, &mouseEvent), "mouse_event_new")
    }

    deinit {
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    /// The colors used where a program sets none (programs can still override them with OSC 10/11/12).
    public func setDefaultColors(foreground: RGB, background: RGB, cursor: RGB? = nil) {
        var fg = GhosttyColorRgb(r: foreground.r, g: foreground.g, b: foreground.b)
        var bg = GhosttyColorRgb(r: background.r, g: background.g, b: background.b)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if let cursor {
            var c = GhosttyColorRgb(r: cursor.r, g: cursor.g, b: cursor.b)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
        }
    }

    /// The 16 ANSI colors (0–7 normal, 8–15 bright); the 256-color cube and grays stay standard.
    public func setPalette(_ ansi: [RGB]) {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { ghostty_color_palette_default($0.baseAddress) }
        for (index, color) in ansi.prefix(16).enumerated() {
            palette[index] = GhosttyColorRgb(r: color.r, g: color.g, b: color.b)
        }
        palette.withUnsafeMutableBufferPointer { buffer in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress)
        }
    }

    /// Feeds program output (escape sequences and text).
    public func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, buffer.count)
        }
    }

    /// Bytes the emulator wants sent to the program (answers to queries, size reports while mode
    /// 2048 is on), collected while writing and resizing. Send them as automatic input.
    public func takeReplies() -> Data {
        defer { replies = Data() }
        return replies
    }

    /// Changes the grid; with mode 2048 on, this queues an in-band size report (`takeReplies()`).
    public func resize(cols: Int, rows: Int) {
        let cols = max(cols, 1), rows = max(rows, 1)
        guard cols != self.cols || rows != self.rows else { return }
        if ghostty_terminal_resize(
            terminal, UInt16(cols), UInt16(rows),
            UInt32(clamping: cellPixels.width), UInt32(clamping: cellPixels.height))
            == GHOSTTY_SUCCESS
        {
            self.cols = cols
            self.rows = rows
        }
    }

    /// Scrolls the viewport through history: negative is up. `nil` jumps back to the bottom.
    public func scroll(by lines: Int?) {
        var behavior = GhosttyTerminalScrollViewport()
        if let lines {
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = lines
        } else {
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        }
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Whether a DEC private mode (`CSI ? n h`) is on.
    public func isPrivateModeEnabled(_ number: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, false), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return false
        }
        return config.value
    }

    /// The program wants pastes wrapped in `ESC[200~` … `ESC[201~` (mode 2004).
    public var bracketedPaste: Bool { isPrivateModeEnabled(2004) }

    // MARK: Screen

    /// Reads the current viewport.
    public func frame() -> ScreenFrame {
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return .empty }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)

        var cursorState = GhosttyRenderStateCursor()
        cursorState.size = MemoryLayout<GhosttyRenderStateCursor>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursorState)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        let rebuildAll = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || cachedLines.count != rows
        var changed = IndexSet()
        var selection: [ClosedRange<Int>?] = []
        selection.reserveCapacity(rows)

        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var codepoints = [UInt32](repeating: 0, count: 16)
        var y = 0
        while ghostty_render_state_row_iterator_next(rowIterator) {
            var rowDirty = true
            _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            if rebuildAll || rowDirty || y >= cachedLines.count {
                _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
                var line: [ScreenCell] = []
                line.reserveCapacity(cols)
                while ghostty_render_state_row_cells_next(rowCells) {
                    line.append(readCell(&codepoints))
                }
                if y < cachedLines.count {
                    if cachedLines[y] != line { changed.insert(y) }
                    cachedLines[y] = line
                } else {
                    cachedLines.append(line)
                    changed.insert(y)
                }
            }
            var range = GhosttyRenderStateRowSelection()
            range.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            if ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &range)
                == GHOSTTY_SUCCESS
            {
                selection.append(Int(range.start_x)...Int(range.end_x))
            } else {
                selection.append(nil)
            }
            y += 1
        }
        if cachedLines.count > y { cachedLines.removeLast(cachedLines.count - y) }
        let lines = cachedLines
        _ = ghostty_render_state_clean(renderState)

        var cursor: ScreenCursor?
        if cursorState.visible && cursorState.viewport_has_value {
            let shape: ScreenCursor.Shape =
                switch cursorState.visual_style {
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .hollowBlock
                default: .block
                }
            cursor = ScreenCursor(
                x: Int(cursorState.viewport_x), y: Int(cursorState.viewport_y),
                shape: shape, blinking: cursorState.blinking)
        }

        return ScreenFrame(
            cols: cols, rows: rows, lines: lines, cursor: cursor,
            foreground: RGB(colors.foreground), background: RGB(colors.background),
            cursorColor: colors.cursor_has_value ? RGB(colors.cursor) : nil,
            selection: selection, changedLines: rebuildAll ? nil : changed, scrollbar: scrollbar(),
            cursorRow: cursorState.viewport_has_value ? Int(cursorState.viewport_y) : nil)
    }

    private func readCell(_ codepoints: inout [UInt32]) -> ScreenCell {
        var raw: GhosttyCell = 0
        _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        let width: UInt8 =
            switch wide {
            case GHOSTTY_CELL_WIDE_WIDE: 2
            case GHOSTTY_CELL_WIDE_SPACER_TAIL, GHOSTTY_CELL_WIDE_SPACER_HEAD: 0
            default: 1
            }

        var length: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
        var text = ""
        if length > 0 {
            if codepoints.count < length { codepoints = [UInt32](repeating: 0, count: Int(length)) }
            codepoints.withUnsafeMutableBufferPointer { buffer in
                _ = ghostty_render_state_row_cells_get(
                    rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress)
            }
            var scalars = String.UnicodeScalarView()
            for value in codepoints.prefix(Int(length)) {
                if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
            }
            text = String(scalars)
        }

        var style = CellStyle()
        var hasStyling = false
        _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
        var color = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color)
            == GHOSTTY_SUCCESS
        {
            style.background = RGB(color)
        }
        if hasStyling {
            var raw = GhosttyStyle()
            raw.size = MemoryLayout<GhosttyStyle>.size
            _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &raw)
            if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color)
                == GHOSTTY_SUCCESS
            {
                style.foreground = RGB(color)
            }
            style.bold = raw.bold
            style.italic = raw.italic
            style.faint = raw.faint
            style.underline = raw.underline != 0
            style.strikethrough = raw.strikethrough
            style.inverse = raw.inverse
            style.invisible = raw.invisible
        }
        var hyperlink = false
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hyperlink)
        return ScreenCell(text: text, style: style, width: width, hyperlink: hyperlink)
    }

    // MARK: Mouse wheel

    public enum WheelResult: Equatable {
        /// Moved our own viewport through history.
        case scrolledLocally
        /// Bytes for the program: mouse wheel reports, or arrow keys on the alternate screen.
        case send(Data)
    }

    /// A scroll of `lines` (negative: up / back) at a cell, routed the way terminals do it:
    /// to the program if it tracks the mouse, as arrow keys in full-screen apps that don't,
    /// otherwise through our own scrollback.
    public func wheel(lines: Int, column: Int, row: Int) -> WheelResult {
        guard lines != 0 else { return .send(Data()) }
        if isMouseTracking {
            prepareMouse()
            ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_PRESS)
            ghostty_mouse_event_set_button(mouseEvent, lines < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE)
            ghostty_mouse_event_set_position(mouseEvent, mousePosition(column: column, row: row))
            var out = Data()
            for _ in 0..<abs(lines) { out.append(encodeMouse()) }
            return .send(out)
        }
        if isAlternateScreen {
            let arrow = encode(lines < 0 ? .up : .down)
            return .send(Data(repeatElement(arrow, count: abs(lines)).joined()))
        }
        scroll(by: lines)
        return .scrolledLocally
    }

    /// The program asked for mouse reports (clicks, wheel).
    public var isMouseTracking: Bool {
        var tracking = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    /// A left click at a cell, encoded for a mouse-tracking program; nil if it doesn't track the mouse.
    public func click(column: Int, row: Int) -> Data? {
        guard isMouseTracking else { return nil }
        prepareMouse()
        ghostty_mouse_event_set_position(mouseEvent, mousePosition(column: column, row: row))
        ghostty_mouse_event_set_button(mouseEvent, GHOSTTY_MOUSE_BUTTON_LEFT)
        var out = Data()
        for action in [GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_ACTION_RELEASE] {
            ghostty_mouse_event_set_action(mouseEvent, action)
            out.append(encodeMouse())
        }
        return out
    }

    /// The cell size behind pixel mouse reports (mode 1016): the one size reports give (programs
    /// like Textual turn pixels back into cells with it), or a made-up one when unknown.
    private var mouseCell: (width: UInt32, height: UInt32) {
        cellPixels.width > 0 && cellPixels.height > 0
            ? (UInt32(clamping: cellPixels.width), UInt32(clamping: cellPixels.height)) : (10, 20)
    }

    private func prepareMouse() {
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
        // Workaround: the first paint of herdr-core 0.1.18 (Ghostty's formatter) replays mode bits
        // in numeric order, so a program that turned on 1015 then 1006 (btop) ends up in urxvt
        // format here, and its SGR parser ignores our clicks. Like xterm, let SGR win whenever
        // its mode is on, and SGR pixels over both.
        var format: GhosttyMouseFormat?
        if isPrivateModeEnabled(1016) {
            format = GHOSTTY_MOUSE_FORMAT_SGR_PIXELS
        } else if isPrivateModeEnabled(1006) {
            format = GHOSTTY_MOUSE_FORMAT_SGR
        }
        if var format { ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT, &format) }
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(cols) * mouseCell.width
        size.screen_height = UInt32(rows) * mouseCell.height
        size.cell_width = mouseCell.width
        size.cell_height = mouseCell.height
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
    }

    private func mousePosition(column: Int, row: Int) -> GhosttyMousePosition {
        GhosttyMousePosition(
            x: Float(UInt32(min(max(column, 0), cols - 1)) * mouseCell.width + mouseCell.width / 2),
            y: Float(UInt32(min(max(row, 0), rows - 1)) * mouseCell.height + mouseCell.height / 2))
    }

    private func encodeMouse() -> Data {
        var buffer = [CChar](repeating: 0, count: 64)
        var written = 0
        guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &buffer, buffer.count, &written)
            == GHOSTTY_SUCCESS
        else { return Data() }
        return Data(bytes: buffer, count: written)
    }

    private func scrollbar() -> Scrollbar? {
        var bar = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) == GHOSTTY_SUCCESS else {
            return nil
        }
        return Scrollbar(total: Int(bar.total), offset: Int(bar.offset), visible: Int(bar.len))
    }

    // MARK: Links

    /// The link at a viewport cell: an OSC 8 hyperlink, or a URL written in the text.
    public func link(at point: (x: Int, y: Int), in frame: ScreenFrame) -> URL? {
        if let ref = gridRef(point), let uri = hyperlinkURI(ref), let url = URL(string: uri) {
            return url
        }
        guard point.y < frame.lines.count else { return nil }
        return LinkDetector.links(in: frame.lines[point.y]).first { $0.columns.contains(point.x) }?.url
    }

    private func hyperlinkURI(_ ref: GhosttyGridRef) -> String? {
        var ref = ref
        var length = 0
        let first = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length)
        guard first == GHOSTTY_OUT_OF_SPACE || first == GHOSTTY_SUCCESS, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_SUCCESS else {
            return nil
        }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    /// Full-screen programs (vim, less, Claude Code) run on the alternate screen.
    public var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    // MARK: Selection

    /// Selects from one viewport cell to another (inclusive). Ghostty keeps the
    /// selection on the same text as the screen scrolls.
    public func select(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        guard let from = gridRef(start), let to = gridRef(end) else { return }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = from
        selection.end = to
        selection.rectangle = false
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// Moves the end of the selection to a viewport cell. Its start stays on the text it was
    /// made on, however far the screen has scrolled since. Without a selection, does nothing.
    public func extendSelection(to end: (x: Int, y: Int)) {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS,
              let ref = gridRef(end)
        else { return }
        selection.end = ref
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// Selects the word under a viewport cell.
    public func selectWord(at point: (x: Int, y: Int)) {
        guard let ref = gridRef(point) else { return }
        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        if ghostty_terminal_select_word(terminal, &options, &selection) == GHOSTTY_SUCCESS {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        }
    }

    public func clearSelection() {
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    /// The selected text as Ghostty copies it: soft wraps joined, trailing spaces trimmed.
    public func selectedText() -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        options.selection = nil
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(terminal, nil, options, &pointer, &length) == GHOSTTY_SUCCESS,
              let pointer
        else { return nil }
        defer { ghostty_free(nil, pointer, length) }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private func gridRef(_ point: (x: Int, y: Int)) -> GhosttyGridRef? {
        var position = GhosttyPoint()
        position.tag = GHOSTTY_POINT_TAG_VIEWPORT
        position.value.coordinate = GhosttyPointCoordinate(
            x: UInt16(clamping: min(max(point.x, 0), cols - 1)), y: UInt32(clamping: min(max(point.y, 0), rows - 1)))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal, position, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    // MARK: Keys

    /// Encodes a key press as the running program expects it (cursor/keypad
    /// application modes, Kitty keyboard protocol, ... are taken from the terminal).
    public func encode(_ key: TerminalKey, modifiers: KeyModifiers = [], text: String? = nil) -> Data {
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
        ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(keyEvent, key.ghostty)
        ghostty_key_event_set_mods(keyEvent, modifiers.rawValue)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, key.unshiftedCodepoint ?? 0)
        let utf8 = Array((text ?? "").utf8)
        utf8.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                ghostty_key_event_set_utf8(keyEvent, $0.baseAddress, $0.count)
            }
        }
        var output = [CChar](repeating: 0, count: 128)
        var written = 0
        let result = ghostty_key_encoder_encode(keyEncoder, keyEvent, &output, output.count, &written)
        guard result == GHOSTTY_SUCCESS else { return Data() }
        return Data(bytes: output, count: written)
    }

    private func check(_ result: GhosttyResult, _ what: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw TerminalError.ghostty(what, Int32(result.rawValue)) }
    }
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let control = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    public static let alt = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    public static let command = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
}

/// Keys the encoder knows by name. Letters and digits carry their own codepoint.
public enum TerminalKey: Hashable, Sendable {
    case enter, tab, backspace, escape, space, delete, insert
    case up, down, left, right, home, end, pageUp, pageDown
    case function(Int)
    case letter(Character)
    case digit(Int)
    case other

    var ghostty: GhosttyKey {
        switch self {
        case .enter: GHOSTTY_KEY_ENTER
        case .tab: GHOSTTY_KEY_TAB
        case .backspace: GHOSTTY_KEY_BACKSPACE
        case .escape: GHOSTTY_KEY_ESCAPE
        case .space: GHOSTTY_KEY_SPACE
        case .delete: GHOSTTY_KEY_DELETE
        case .insert: GHOSTTY_KEY_INSERT
        case .up: GHOSTTY_KEY_ARROW_UP
        case .down: GHOSTTY_KEY_ARROW_DOWN
        case .left: GHOSTTY_KEY_ARROW_LEFT
        case .right: GHOSTTY_KEY_ARROW_RIGHT
        case .home: GHOSTTY_KEY_HOME
        case .end: GHOSTTY_KEY_END
        case .pageUp: GHOSTTY_KEY_PAGE_UP
        case .pageDown: GHOSTTY_KEY_PAGE_DOWN
        case .function(let n) where (1...12).contains(n):
            GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + Int32(n - 1))
        case .letter(let c):
            if let ascii = c.lowercased().unicodeScalars.first?.value, (97...122).contains(ascii) {
                GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + Int32(ascii) - 97)
            } else {
                GHOSTTY_KEY_UNIDENTIFIED
            }
        case .digit(let d) where (0...9).contains(d):
            // DIGIT_0 sits right before DIGIT_1.
            GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_1.rawValue + Int32(d) - 1)
        default: GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    var unshiftedCodepoint: UInt32? {
        switch self {
        case .letter(let c): c.lowercased().unicodeScalars.first?.value
        case .digit(let d): UInt32(48 + d)
        case .space: 32
        default: nil
        }
    }
}
