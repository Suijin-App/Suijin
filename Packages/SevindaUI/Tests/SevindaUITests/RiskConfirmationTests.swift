import Testing
@testable import SevindaUI

struct RiskConfirmationTests {
    @Test func safeActionsDoNotPrompt() {
        let request = RiskConfirmationRequest(level: .safe, title: "Xem dung lượng disk")
        #expect(!request.needsPrompt)
        #expect(request.canConfirm(typed: ""))
    }

    @Test func confirmLevelAlwaysUnlocked() {
        let request = RiskConfirmationRequest(level: .confirm, title: "Restart tek-api", typeToConfirm: "prod-api-01")
        #expect(request.needsPrompt)
        #expect(request.canConfirm(typed: ""))
    }

    @Test func dangerRequiresExactName() {
        let request = RiskConfirmationRequest(level: .danger, title: "Dọn Docker", typeToConfirm: "prod-api-01")
        #expect(!request.canConfirm(typed: ""))
        #expect(!request.canConfirm(typed: "prod-api"))
        #expect(!request.canConfirm(typed: "PROD-API-01"))
        #expect(request.canConfirm(typed: "prod-api-01"))
        #expect(request.canConfirm(typed: "  prod-api-01\n"))
    }

    @Test func dangerWithoutNameIsUnlocked() {
        let request = RiskConfirmationRequest(level: .danger, title: "Xoá file")
        #expect(request.canConfirm(typed: ""))
    }
}
