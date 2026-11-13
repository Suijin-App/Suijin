import Testing
@testable import SuijinUI

@MainActor
struct ProgressModelTests {
    @Test func successfulRunMarksEveryStepDone() async {
        let model = ProgressModel(title: "Pull & Up", steps: ["Tải image", "Tạo lại container"])
        let stream = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            continuation.yield(.stepStarted(0))
            continuation.yield(.log("Pulling tekmium/api"))
            continuation.yield(.stepFinished(0))
            continuation.yield(.stepStarted(1))
            continuation.yield(.stepFinished(1))
            continuation.finish()
        }
        await model.run(stream)
        #expect(model.steps == [.done, .done])
        #expect(model.outcome == .succeeded)
        #expect(model.fractionComplete == 1)
        #expect(model.log == "Pulling tekmium/api")
    }

    @Test func failureStopsAtRunningStep() async {
        let model = ProgressModel(title: "Lưu file", steps: ["Sao lưu", "Ghi", "Kiểm tra"])
        let stream = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            continuation.yield(.stepStarted(0))
            continuation.yield(.stepFinished(0))
            continuation.yield(.stepStarted(1))
            continuation.yield(.failed("Permission denied"))
            continuation.yield(.stepStarted(2))
            continuation.finish()
        }
        await model.run(stream)
        #expect(model.steps == [.done, .failed, .pending])
        #expect(model.outcome == .failed("Permission denied"))
    }

    @Test func stepFailureKeepsTheRunGoing() async {
        let model = ProgressModel(title: "Restart 2 container", steps: ["web", "api"])
        let stream = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            continuation.yield(.stepStarted(0))
            continuation.yield(.stepFailed(0))
            continuation.yield(.stepStarted(1))
            continuation.yield(.stepFinished(1))
            continuation.yield(.failed("1 container lỗi"))
            continuation.finish()
        }
        await model.run(stream)
        #expect(model.steps == [.failed, .done])
        #expect(model.outcome == .failed("1 container lỗi"))
    }

    @Test func thrownErrorBecomesFailure() async {
        struct Boom: Error {}
        let model = ProgressModel(title: "Recipe", steps: ["Chạy"])
        let stream = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            continuation.yield(.stepStarted(0))
            continuation.finish(throwing: Boom())
        }
        await model.run(stream)
        #expect(model.steps == [.failed])
        if case .failed = model.outcome {} else { Issue.record("expected failure outcome") }
    }

    @Test func outOfRangeStepsAreIgnored() {
        let model = ProgressModel(title: "x", steps: ["a"])
        model.apply(.stepStarted(5))
        #expect(model.steps == [.pending])
    }

    @Test func stopIsOfferedOnlyWhileAStoppableRunIsGoing() {
        let plain = ProgressModel(title: "Pull & Up", steps: ["Tải image"])
        #expect(!plain.canStop)

        let model = ProgressModel(title: "Recipe", steps: ["Chạy"])
        var stops = 0
        model.stopHandler = { stops += 1 }
        #expect(model.canStop)
        model.stop()
        model.stop()
        // One request: the button is disabled while the operation winds down.
        #expect(stops == 1)
        #expect(model.isStopping && !model.canStop)
        model.apply(.failed("Đã dừng."))
        #expect(model.outcome == .failed("Đã dừng."))

        let finished = ProgressModel(title: "Recipe", steps: ["Chạy"])
        finished.stopHandler = { stops += 1 }
        finished.finish()
        finished.stop()
        #expect(stops == 1)
    }
}
