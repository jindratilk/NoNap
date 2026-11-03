import Foundation
import Testing
@testable import NoNap

/// A pretend Mac whose setting can lag behind the command, like the real one.
@MainActor
private final class FakeMac {
    var value: Bool?
    /// Reads that still return the old value after a write.
    var staleReads = 0
    var writes: [Bool] = []
    var error: Error?
    var login = false
    var writeGate: AsyncStream<Void>?

    init(_ value: Bool?) { self.value = value }

    private func applied(_ wanted: Bool) async throws {
        writes.append(wanted)
        if let writeGate { for await _ in writeGate { break } }
        if let error { throw error }
        value = wanted
    }

    func read() -> Bool? {
        if staleReads > 0 {
            staleReads -= 1
            return !(value ?? false)
        }
        return value
    }

    var system: KeepAwake.System {
        KeepAwake.System(
            read: { self.read() },
            write: { wanted in try await self.applied(wanted) },
            launchesAtLogin: { self.login },
            setLaunchesAtLogin: { self.login = $0 }
        )
    }
}

@MainActor
private func settled(_ model: KeepAwake) async {
    for _ in 0..<500 where model.target != nil { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
    #expect(model.target == nil)
}

@MainActor
private func make(_ mac: FakeMac, attempts: Int = 30) -> KeepAwake {
    KeepAwake(system: mac.system, confirmAttempts: attempts, confirmDelay: .milliseconds(1), problemDuration: .milliseconds(20))
}

@MainActor
struct KeepAwakeTests {
    @Test func readsTheSystemAtStart() {
        #expect(make(FakeMac(true)).isOn == true)
        #expect(make(FakeMac(false)).isOn == false)
    }

    @Test func unknownStateIsNotReportedAsOff() {
        let model = make(FakeMac(nil))
        #expect(model.isUnknown)
        #expect(model.isOn == false)
    }

    @Test func picksUpChangesMadeElsewhere() {
        let mac = FakeMac(false)
        let model = make(mac)
        mac.value = true
        model.refresh()
        #expect(model.isOn == true)
        mac.value = false
        model.refresh()
        #expect(model.isOn == false)
    }

    @Test func showsTheNewStateRightAway() async {
        let mac = FakeMac(false)
        let model = make(mac)
        model.toggle()
        #expect(model.isOn == true)
        await settled(model)
        #expect(mac.writes == [true])
        #expect(model.isOn == true)
        #expect(model.problem == nil)
    }

    /// The bug this model exists to fix: right after the command, a read can return the old value.
    @Test func aStaleReadAfterTheCommandDoesNotFlipTheSwitchBack() async {
        let mac = FakeMac(false)
        let model = make(mac)
        mac.staleReads = 5
        model.toggle()
        model.refresh()
        #expect(model.isOn == true)
        await settled(model)
        #expect(model.isOn == true)
        #expect(model.actual == true)
        #expect(model.problem == nil)
    }

    @Test func pollingDuringAChangeDoesNotOverrideIt() async {
        let mac = FakeMac(true)
        let model = make(mac)
        var finish: AsyncStream<Void>.Continuation!
        mac.writeGate = AsyncStream { finish = $0 }
        model.toggle()
        await Task.yield()
        model.refresh()
        #expect(model.isOn == false)
        finish.yield()
        await settled(model)
        #expect(model.isOn == false)
    }

    @Test func ignoresTapsWhileAChangeIsRunning() async {
        let mac = FakeMac(false)
        let model = make(mac)
        model.toggle()
        model.toggle()
        model.toggle()
        await settled(model)
        #expect(mac.writes == [true])
        #expect(model.isOn == true)
    }

    @Test func aFailedCommandGoesBackAndSaysSo() async {
        let mac = FakeMac(false)
        mac.error = Power.Failure.command("nope")
        let model = make(mac)
        model.toggle()
        await settled(model)
        #expect(model.isOn == false)
        #expect(model.problem != nil)
    }

    @Test func cancellingThePasswordDialogIsNotAnError() async {
        let mac = FakeMac(false)
        mac.error = Power.Failure.cancelled
        let model = make(mac)
        model.toggle()
        await settled(model)
        #expect(model.isOn == false)
        #expect(model.problem == nil)
    }

    @Test func aChangeThatNeverTakesEffectShowsTheRealState() async {
        let mac = FakeMac(false)
        let model = make(mac, attempts: 3)
        mac.staleReads = 1000
        model.toggle()
        await settled(model)
        #expect(model.problem != nil)
        mac.staleReads = 0
        model.refresh()
        #expect(model.isOn == true)
    }

    @Test func problemsClearThemselves() async throws {
        let mac = FakeMac(false)
        mac.error = Power.Failure.command("nope")
        let model = make(mac)
        model.toggle()
        await settled(model)
        #expect(model.problem != nil)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.problem == nil)
    }

    @Test func loginItemFollowsTheSystem() {
        let mac = FakeMac(false)
        let model = make(mac)
        model.setLaunchesAtLogin(true)
        #expect(mac.login == true)
        #expect(model.launchesAtLogin == true)
    }
}

/// Read-only checks against this Mac. Nothing here changes the power setting.
struct PowerTests {
    @Test func agreesWithPmset() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let line = output.split(separator: "\n").first { $0.contains("SleepDisabled") }
        let pmset = line?.split(whereSeparator: \.isWhitespace).last == "1"
        #expect(Power.isSleepDisabled() == pmset)
    }

    @Test func isCheapEnoughToPoll() {
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<100 { _ = Power.isSleepDisabled() } }
        #expect(elapsed < .milliseconds(100))
    }
}
