import Testing
@testable import SevindaUI

@MainActor
struct PaletteFilterTests {
    private func command(_ title: String, _ subtitle: String = "") -> PaletteCommand {
        PaletteCommand(id: title, title: title, subtitle: subtitle) {}
    }

    @Test func emptyQueryKeepsOrder() {
        let commands = [command("Thêm host"), command("Restart app tek-api")]
        #expect(PaletteFilter.filter(commands, query: "").map(\.id) == ["Thêm host", "Restart app tek-api"])
    }

    @Test func ignoresCaseAndVietnameseDiacritics() {
        let commands = [command("Dọn Docker"), command("Đi tới: Tổng quan"), command("Thêm host")]
        #expect(PaletteFilter.filter(commands, query: "don docker").map(\.id) == ["Dọn Docker"])
        #expect(PaletteFilter.filter(commands, query: "di toi tong").map(\.id) == ["Đi tới: Tổng quan"])
    }

    @Test func everyWordMustMatch() {
        let commands = [command("Restart app tek-api"), command("Restart app redis")]
        #expect(PaletteFilter.filter(commands, query: "restart redis").map(\.id) == ["Restart app redis"])
    }

    @Test func wordStartRanksAboveSubstring() {
        let commands = [command("Prune image"), command("Mở Recipes", "recipe")]
        let result = PaletteFilter.filter(commands, query: "re")
        #expect(result.first?.id == "Mở Recipes")
    }

    @Test func subtitleIsSearchable() {
        let commands = [command("Chuyển host: prod-api-01", "103.21.84.12")]
        #expect(PaletteFilter.filter(commands, query: "103.21").count == 1)
    }
}
