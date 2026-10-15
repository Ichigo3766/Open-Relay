import Foundation

enum Phase { case active, inactive, background }
@MainActor final class Checker {
    var starts: [ContinuousClock.Instant] = []
    func checkForUpdates() async {
        starts.append(.now)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    func checkForUpdates(using: Int?) async { await checkForUpdates() }
}
@MainActor final class Dependencies {
    let updateChecker = Checker()
    let serverUpdateChecker = Checker()
    var apiClient: Int? = 1
}
@MainActor final class Harness {
    let dependencies = Dependencies()
    var scenePhase: Phase = .active
    let phaseTask = // PHASE_TASK
    func rootWork() async {
        // ROOT_WORK
    }
    func appForegroundWork() async {
        // FOREGROUND_WORK
    }
    func coldLaunch() async {
        async let root: Void = rootWork()
        async let foreground: Void = appForegroundWork()
        _ = await (root, foreground)
    }
    func resume() async {
        scenePhase = .active
        if phaseTask { await rootWork() } else { await appForegroundWork() }
    }
}

@main struct Checks {
    @MainActor static func main() async {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let cold = Harness()
        await cold.coldLaunch()
        let app = cold.dependencies.updateChecker.starts
        let server = cold.dependencies.serverUpdateChecker.starts
        print("MEASURE cold_launch app_batches=\(app.count) server_batches=\(server.count)")
        check(app.count == 1 && server.count == 1, "one automatic batch on cold launch")
        if let a = app.first, let b = server.first {
            let gap = a < b ? a.duration(to: b) : b.duration(to: a)
            check(gap < .milliseconds(15), "app and server checks remain parallel")
        }
        await cold.resume()
        check(cold.dependencies.updateChecker.starts.count == app.count + 1, "app checks again on foreground return")
        check(cold.dependencies.serverUpdateChecker.starts.count == server.count + 1, "server checks again on foreground return")
        let inactive = Harness()
        inactive.scenePhase = .inactive
        await inactive.rootWork()
        check(inactive.dependencies.updateChecker.starts.isEmpty, "no automatic requests while inactive")
        let background = Harness()
        background.scenePhase = .background
        await background.rootWork()
        check(background.dependencies.serverUpdateChecker.starts.isEmpty, "no automatic requests while backgrounded")
        let cancelled = Harness()
        let task = Task { await cancelled.rootWork() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        await task.value
        check(cancelled.dependencies.updateChecker.starts.isEmpty, "cancelled presentation delay starts no requests")
        let quickSwitch = Harness()
        let stale = Task { await quickSwitch.rootWork() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        stale.cancel()
        quickSwitch.scenePhase = .inactive
        await stale.value
        await quickSwitch.resume()
        check(quickSwitch.dependencies.updateChecker.starts.count == 1, "quick inactive-active transition starts one live batch")
        print("\(checks) checks; \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
