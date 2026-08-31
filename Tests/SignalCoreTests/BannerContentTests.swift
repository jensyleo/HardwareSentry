import Testing
@testable import SignalCore

@Suite("BannerContent")
struct BannerContentTests {
    @Test("a plain line is left alone")
    func plainLineUnchanged() {
        let content = BannerContent(event: makeEvent(body: "SanDisk Cruzer"))

        #expect(content.lines == [.init(leading: "SanDisk Cruzer")])
    }

    // What changed is the news, so it is set apart from the label that introduces it.
    @Test("a reported change is split so the new value stands out")
    func changeIsSplit() {
        let content = BannerContent(event: makeEvent(body: "Sample rate:\t44100 Hz → 48000 Hz"))

        #expect(content.lines == [.init(leading: "Sample rate:\t44100 Hz → ", emphasised: "48000 Hz")])
    }

    @Test("each line is considered on its own")
    func linesConsideredIndependently() {
        let content = BannerContent(event: makeEvent(body: "Studio Display\nBrightness: 40% → 75%"))

        #expect(content.lines.count == 2)
        #expect(content.lines[0].emphasised == nil)
        #expect(content.lines[1].emphasised == "75%")
    }

    @Test("only the first arrow splits the line")
    func firstArrowWins() {
        let content = BannerContent(event: makeEvent(body: "a → b → c"))

        #expect(content.lines == [.init(leading: "a → ", emphasised: "b → c")])
    }

    @Test("a trailing arrow with nothing after it is not a change")
    func trailingArrowIsNotAChange() {
        let content = BannerContent(event: makeEvent(body: "Disconnected → "))

        #expect(content.lines == [.init(leading: "Disconnected → ")])
    }

    @Test("an empty body yields no lines")
    func emptyBodyHasNoLines() {
        let content = BannerContent(event: makeEvent(body: ""))

        #expect(content.lines.isEmpty)
    }

    @Test("blank lines are dropped rather than drawn as gaps")
    func blankLinesDropped() {
        let content = BannerContent(event: makeEvent(body: "First\n\nSecond"))

        #expect(content.lines.map(\.leading) == ["First", "Second"])
    }

    @Test("the title and icon are carried through untouched")
    func titleAndIconCarried() {
        var event = makeEvent(title: "USB Device Connected")
        event.icon = .symbol("cable.connector")
        let content = BannerContent(event: event)

        #expect(content.title == "USB Device Connected")
        #expect(content.icon == .symbol("cable.connector"))
    }
}
