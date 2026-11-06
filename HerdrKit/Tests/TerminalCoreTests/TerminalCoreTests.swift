import Foundation
import Testing
@testable import TerminalCore

private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Test func writesTextAndStyles() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 4)
    vt.write(bytes("Hello, \u{1b}[1;32mworld\u{1b}[0m!\r\n\u{1b}[38;2;255;128;0morange\u{1b}[0m"))
    let frame = vt.frame()
    #expect(frame.cols == 20)
    #expect(frame.lines.count == 4)
    #expect(frame.text.hasPrefix("Hello, world!\norange"))

    let w = frame.lines[0][7]
    #expect(w.text == "w")
    #expect(w.style.bold)
    #expect(w.style.foreground != nil)
    #expect(frame.lines[1][0].style.foreground == RGB(r: 255, g: 128, b: 0))
    #expect(frame.lines[0][0].style == .plain)
    #expect(frame.cursor?.x == 6)
    #expect(frame.cursor?.y == 1)
}

@Test func wideCharactersTakeTwoCells() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 2)
    vt.write(bytes("a漢b"))
    let line = vt.frame().lines[0]
    #expect(line[0].text == "a")
    #expect(line[1].text == "漢")
    #expect(line[1].width == 2)
    #expect(line[2].width == 0)
    #expect(line[3].text == "b")
}

@Test func resizeAndScrollback() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    for i in 1...10 { vt.write(bytes("line \(i)\r\n")) }
    #expect(vt.frame().text.contains("line 10"))
    vt.scroll(by: -5)
    #expect(vt.frame().text.contains("line 5"))
    vt.scroll(by: nil)
    #expect(vt.frame().text.contains("line 10"))
    vt.resize(cols: 30, rows: 5)
    #expect(vt.frame().lines.count == 5)
    #expect(vt.frame().lines[0].count == 30)
}

@Test func keysFollowTerminalModes() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 2)
    #expect(vt.encode(.enter) == bytes("\r"))
    #expect(vt.encode(.letter("c"), modifiers: .control) == Data([0x03]))
    #expect(vt.encode(.up) == bytes("\u{1b}[A"))
    #expect(vt.encode(.letter("a"), text: "a") == bytes("a"))
    // A full-screen program turns on application cursor keys (DECCKM).
    vt.write(bytes("\u{1b}[?1h"))
    #expect(vt.encode(.up) == bytes("\u{1b}OA"))
}

@Test func tracksBracketedPasteMode() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 2)
    #expect(!vt.bracketedPaste)
    vt.write(bytes("\u{1b}[?2004h"))
    #expect(vt.bracketedPaste)
    vt.write(bytes("\u{1b}[?2004l"))
    #expect(!vt.bracketedPaste)
}

@Test func wheelScrollsHistoryInAShell() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    for i in 1...10 { vt.write(bytes("line \(i)\r\n")) }
    #expect(vt.wheelScrollsLocally)
    #expect(vt.wheel(lines: -5, column: 0, row: 0) == .scrolledLocally)
    #expect(vt.frame().text.contains("line 5"))
}

@Test func wheelScrollsLocallyOnlyWithoutAProgramTakingIt() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    vt.write(bytes("\u{1b}[?1000h"))
    #expect(!vt.wheelScrollsLocally)
    vt.write(bytes("\u{1b}[?1000l\u{1b}[?1049h"))
    #expect(!vt.wheelScrollsLocally)
    vt.write(bytes("\u{1b}[?1049l"))
    #expect(vt.wheelScrollsLocally)
}

@Test func linesNextToTheViewport() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    for i in 1...10 { vt.write(bytes("line \(i)\r\n")) }
    func text(_ line: [ScreenCell]?) -> String? {
        line.map { cells in
            cells.map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces)
        }
    }

    vt.scroll(by: -4)  // lines 5 to 7
    let shown = vt.frame().text
    #expect(text(vt.lineNextToViewport(above: true)) == "line 4")
    #expect(text(vt.lineNextToViewport(above: false)) == "line 8")
    #expect(vt.frame().text == shown)

    vt.scroll(by: -100)  // the top: lines 1 to 3
    #expect(vt.lineNextToViewport(above: true) == nil)
    #expect(text(vt.lineNextToViewport(above: false)) == "line 4")

    vt.scroll(by: nil)  // the bottom
    #expect(vt.lineNextToViewport(above: false) == nil)
    #expect(text(vt.lineNextToViewport(above: true)) == "line 8")
}

@Test func wheelSendsArrowsInFullScreenApps() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    vt.write(bytes("\u{1b}[?1049h"))  // alternate screen, no mouse tracking (less, older TUIs)
    #expect(vt.isAlternateScreen)
    #expect(vt.wheel(lines: -2, column: 0, row: 0) == .send(bytes("\u{1b}[A\u{1b}[A")))
    #expect(vt.wheel(lines: 1, column: 0, row: 0) == .send(bytes("\u{1b}[B")))
}

@Test func wheelReportsToMouseTrackingPrograms() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    vt.write(bytes("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h"))  // vim/Claude Code style: SGR mouse
    // Wheel up is button 64 in SGR encoding, at 1-based cell coordinates.
    #expect(vt.wheel(lines: -1, column: 2, row: 1) == .send(bytes("\u{1b}[<64;3;2M")))
    #expect(vt.wheel(lines: 2, column: 0, row: 0) == .send(bytes("\u{1b}[<65;1;1M\u{1b}[<65;1;1M")))
}

@Test func selectsAndCopiesText() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 3)
    vt.write(bytes("hello world\r\nsecond line"))
    vt.select(from: (6, 0), to: (5, 1))
    #expect(vt.selectedText() == "world\nsecond")
    let frame = vt.frame()
    #expect(frame.selection[0] == 6...19)
    #expect(frame.selection[1] == 0...5)
    #expect(frame.selection[2] == nil)

    vt.selectWord(at: (8, 0))
    #expect(vt.selectedText() == "world")
    vt.clearSelection()
    #expect(vt.selectedText() == nil)
}

@Test func selectionKeepsItsStartWhenDraggingUpThroughHistory() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    for i in 1...10 { vt.write(bytes("line \(i)\r\n")) }
    vt.select(from: (0, 1), to: (0, 1))  // the "l" of "line 10"
    vt.scroll(by: -4)
    #expect(vt.frame().text.contains("line 5"))
    vt.extendSelection(to: (0, 0))  // the "l" of "line 5": the same row number showed "line 9" before
    #expect(vt.selectedText() == "line 5\nline 6\nline 7\nline 8\nline 9\nl")
    #expect(vt.frame().selection == [0...9, 0...9, 0...9])
}

@Test func selectionKeepsItsStartWhenDraggingDownThroughHistory() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    for i in 1...10 { vt.write(bytes("line \(i)\r\n")) }
    vt.scroll(by: -6)
    vt.select(from: (5, 0), to: (5, 0))  // the "3" of "line 3"
    vt.scroll(by: 2)
    vt.extendSelection(to: (5, 2))  // the "7" of "line 7"
    #expect(vt.selectedText() == "3\nline 4\nline 5\nline 6\nline 7")
}

@Test func extendingWithoutASelectionDoesNothing() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    vt.write(bytes("hello"))
    vt.extendSelection(to: (2, 0))
    #expect(vt.selectedText() == nil)
}

@Test func framesReportOnlyChangedLines() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 5)
    vt.write(bytes("one\r\ntwo\r\nthree"))
    #expect(vt.frame().changedLines == nil)  // first frame: everything
    vt.write(bytes("\u{1b}[2;1Hxx"))
    #expect(vt.frame().changedLines == IndexSet(integer: 1))
    #expect(vt.frame().changedLines == IndexSet())
}

/// Rough cost of reading a busy screen (prints, does not assert a time).
@Test func frameCost() throws {
    let vt = try VirtualTerminal(cols: 160, rows: 50)
    var text = ""
    for i in 0..<50 { text += "\u{1b}[3\(i % 8)m" + String(repeating: "x", count: 150) + "\u{1b}[0m\r\n" }
    vt.write(bytes(text))
    let clock = ContinuousClock()
    let full = clock.measure { _ = vt.frame() }
    vt.write(bytes("\u{1b}[10;1Hchanged"))
    let incremental = clock.measure { _ = vt.frame() }
    print("frame 160x50: full \(full), one changed line \(incremental)")
}

/// The bytes that made Claude Code 2.1.319's fullscreen renderer select a word, drag, scroll at
/// the edge and copy, tried against the real thing.
@Test func mouseDragsSelectByWordThenMoveAndRelease() throws {
    let vt = try VirtualTerminal(cols: 80, rows: 24)
    #expect(!vt.tracksMouseDrags)
    #expect(vt.mouseDrag(.press, column: 10, row: 5).isEmpty)
    vt.write(bytes("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h"))
    #expect(vt.tracksMouseDrags)
    #expect(vt.mouseDrag(.press, column: 10, row: 5) == bytes("\u{1b}[<0;11;6M\u{1b}[<0;11;6m\u{1b}[<0;11;6M"))
    #expect(vt.mouseDrag(.move, column: 10, row: 0) == bytes("\u{1b}[<32;11;1M"))
    #expect(vt.mouseDrag(.release, column: 10, row: 0) == bytes("\u{1b}[<0;11;1m"))
}

@Test func clicksAloneAreNotDrags() throws {
    let vt = try VirtualTerminal(cols: 80, rows: 24)
    vt.write(bytes("\u{1b}[?1000h\u{1b}[?1006h"))
    #expect(vt.isMouseTracking)
    #expect(!vt.tracksMouseDrags)
}

@Test func clipboardWritesOnlyWhileAllowedAndOnlyOnce() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 3)
    let copyHello = bytes("\u{1b}]52;c;aGVsbG8=\u{7}")
    vt.write(copyHello)
    #expect(vt.takeClipboardWrite() == nil)

    vt.clipboardWritesAllowedUntil = ContinuousClock.now.advanced(by: .seconds(5))
    vt.write(copyHello)
    #expect(vt.takeClipboardWrite() == "hello")
    #expect(vt.takeClipboardWrite() == nil)
    vt.write(copyHello)
    #expect(vt.takeClipboardWrite() == nil)

    vt.clipboardWritesAllowedUntil = ContinuousClock.now.advanced(by: .seconds(-1))
    vt.write(copyHello)
    #expect(vt.takeClipboardWrite() == nil)
}

@Test func clicksOnlyReachMouseTrackingPrograms() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    #expect(vt.click(column: 1, row: 1) == nil)
    vt.write(bytes("\u{1b}[?1000h\u{1b}[?1006h"))
    #expect(vt.click(column: 1, row: 1) == bytes("\u{1b}[<0;2;2M\u{1b}[<0;2;2m"))
}

@Test func scrollbarFollowsHistory() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 3)
    for i in 1...10 { vt.write(bytes("line \(i)\r\n")) }
    let bottom = try #require(vt.frame().scrollbar)
    #expect(bottom.visible == 3)
    #expect(bottom.total > 3)
    #expect(bottom.atBottom)
    vt.scroll(by: -4)
    let back = try #require(vt.frame().scrollbar)
    #expect(!back.atBottom)
    #expect(back.offset == bottom.offset - 4)
}

@Test func osc8HyperlinksAreLinks() throws {
    let vt = try VirtualTerminal(cols: 30, rows: 2)
    vt.write(bytes("see \u{1b}]8;;https://herdr.dev/docs\u{1b}\\the docs\u{1b}]8;;\u{1b}\\ now"))
    let frame = vt.frame()
    #expect(frame.lines[0][5].hyperlink)
    #expect(!frame.lines[0][1].hyperlink)
    #expect(vt.link(at: (6, 0), in: frame) == URL(string: "https://herdr.dev/docs"))
    #expect(vt.link(at: (1, 0), in: frame) == nil)
}

@Test func detectsPlainTextURLs() throws {
    let vt = try VirtualTerminal(cols: 60, rows: 2)
    vt.write(bytes("PR: (https://github.com/x/y/pull/1). 漢 http://a.b/c?d=1,"))
    let frame = vt.frame()
    let links = LinkDetector.links(in: frame.lines[0])
    #expect(links.map(\.url.absoluteString) == ["https://github.com/x/y/pull/1", "http://a.b/c?d=1"])
    #expect(links[0].columns == 5...33)
    // The wide character before the second link shifts columns by one cell.
    #expect(vt.link(at: (42, 0), in: frame)?.host == "a.b")
    #expect(LinkDetector.links(in: try VirtualTerminal(cols: 20, rows: 1).frame().lines[0]).isEmpty)
}

@Test func defaultColorsApplyToTheFrame() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 2)
    vt.setDefaultColors(foreground: RGB(r: 0xd9, g: 0xda, b: 0xd8), background: RGB(r: 0x1f, g: 0x21, b: 0x24))
    vt.write(Data("hi".utf8))
    let frame = vt.frame()
    #expect(frame.background == RGB(r: 0x1f, g: 0x21, b: 0x24))
    #expect(frame.foreground == RGB(r: 0xd9, g: 0xda, b: 0xd8))
}

@Test func paletteColorsANSIText() throws {
    let vt = try VirtualTerminal(cols: 10, rows: 2)
    var ansi = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: 16)
    ansi[1] = RGB(r: 0xe0, g: 0x6c, b: 0x75)
    vt.setPalette(ansi)
    vt.write(Data("\u{1b}[31mx".utf8))
    #expect(vt.frame().lines[0][0].style.foreground == RGB(r: 0xe0, g: 0x6c, b: 0x75))
}

/// Spinners and coding agents hide the cursor; its row still says where the action is.
@Test func hiddenCursorKeepsItsRow() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 10)
    vt.write(bytes("one\r\ntwo\r\n\u{1b}[?25l⠋ Loading..."))
    let frame = vt.frame()
    #expect(frame.cursor == nil)
    #expect(frame.cursorRow == 2)
}

/// Textual ignores SIGWINCH once mode 2048 is on: the size has to come back as an in-band report.
@Test func reportsSizeInBandWithMode2048() throws {
    let vt = try VirtualTerminal(cols: 80, rows: 24)
    vt.cellPixels = (10, 20)
    vt.resize(cols: 100, rows: 30)
    #expect(vt.takeReplies().isEmpty)

    vt.write(Data("\u{1b}[?2048h".utf8))
    #expect(String(decoding: vt.takeReplies(), as: UTF8.self) == "\u{1b}[48;30;100;600;1000t")

    vt.resize(cols: 120, rows: 40)
    #expect(String(decoding: vt.takeReplies(), as: UTF8.self) == "\u{1b}[48;40;120;800;1200t")
    #expect(vt.takeReplies().isEmpty)
}

/// Pixel mouse reports (mode 1016) use the cell size the size reports give, or clicks land elsewhere.
@Test func pixelMouseReportsUseTheReportedCellSize() throws {
    let vt = try VirtualTerminal(cols: 80, rows: 24)
    vt.cellPixels = (17, 33)
    vt.write(Data("\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1016h".utf8))
    let click = String(decoding: vt.click(column: 10, row: 5) ?? Data(), as: UTF8.self)
    // The middle of cell (10, 5): 10 × 17 + 8, 5 × 33 + 16.
    #expect(click.hasPrefix("\u{1b}[<0;178;181M"))
}

/// herdr-core's first paint sets 1006 before 1015 (btop sent them the other way round):
/// clicks must still be SGR, which is all btop parses.
@Test func sgrMouseWinsOverUrxvt() throws {
    let vt = try VirtualTerminal(cols: 80, rows: 24)
    vt.write(Data("\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1015h".utf8))
    let click = String(decoding: vt.click(column: 10, row: 5) ?? Data(), as: UTF8.self)
    #expect(click == "\u{1b}[<0;11;6M\u{1b}[<0;11;6m")
}
