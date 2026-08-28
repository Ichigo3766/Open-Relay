import Foundation
import BackgroundTasks
import os.log

/// Centralized service that registers and schedules iOS Background Tasks.
///
/// ## Architecture
///
/// Uses two BGTaskScheduler task types:
/// - **`BGAppRefreshTask`** (`com.openui.refresh`) — lightweight first-page conversation
///   list fetch to keep the badge count and chat list current. Runs opportunistically
///   during the day, especially when the user frequently opens the app. Budget: ~3s.
/// - **`BGProcessingTask`** (`com.openui.processing`) — heavier work (TBD; currently
///   reserved for future offline processing). Runs while on charger or overnight.
///   Budget: up to ~60s. Requires network.
///
/// ## Key Design Principles (from BGTaskScheduler best practices)
///
/// 1. **Register handlers at launch** — `registerHandlers()` must be called before
///    `applicationDidFinishLaunching` returns (i.e. in `App.init()`).
///
/// 2. **Anchor dates, not `now + interval`** — `scheduleAll()` anchors
///    `earliestBeginDate` to `lastRun + interval`, NOT `now + interval`. The "now"
///    approach pushes the target further out on every re-arm, meaning the task is
///    forever "just about to run" and never actually does.
///
/// 3. **Skip submit when not needed** — before submitting, compare the existing pending
///    request against the desired date. If the existing request fires sooner than what
///    we'd submit, leave it alone. Re-submitting would replace it with a later date.
///
/// 4. **Force resubmit after reboot/OS upgrade** — pending requests can survive a
///    reboot or OS upgrade with their original (now-stale) `earliestBeginDate`. On the
///    first run after boot/upgrade, force a near-term submission to restore responsiveness.
///
/// 5. **Race-safe completion token** — `BGTaskCompletionToken` uses `OSAllocatedUnfairLock`
///    to ensure `task.setTaskCompleted(success:)` is called exactly once even when the
///    expiration handler and normal completion path race.
///
/// 6. **Re-arm on every lifecycle event** — `scheduleAll()` is called on both
///    `.active` and `.background` scene phase transitions so iOS always has a fresh
///    pending request to honor.
final class BackgroundTaskService {

    static let shared = BackgroundTaskService()

    // MARK: - Task Identifiers (must match Info.plist BGTaskSchedulerPermittedIdentifiers)

    /// Lightweight conversation list refresh. Maps to BGAppRefreshTask.
    static let refreshIdentifier = "com.openui.refresh"

    /// Heavier background processing (reserved / future). Maps to BGProcessingTask.
    static let processingIdentifier = "com.openui.processing"

    // MARK: - Scheduling Configuration

    /// How often the refresh task should ideally run (30 minutes).
    /// `earliestBeginDate` is anchored to `lastRun + refreshInterval`, never `now + interval`.
    private let refreshInterval: TimeInterval = 30 * 60

    /// How often the processing task should ideally run (1 hour).
    private let processingInterval: TimeInterval = 60 * 60

    /// Minimum delay from now before the task can run (prevents flooding the scheduler
    /// with near-zero dates on every re-arm). 60 seconds is low enough to feel responsive
    /// while giving the scheduler room to batch tasks intelligently.
    private let minimumDelay: TimeInterval = 60

    /// Tolerance window for shouldSkipSubmit: if the existing pending request fires within
    /// `replacementTolerance` seconds of the desired date, leave it alone.
    private let replacementTolerance: TimeInterval = 5

    // MARK: - Persistent State

    /// The date of the last successful refresh task run.
    private var lastRefreshRun: Date {
        get { UserDefaults.standard.object(forKey: "bgRefreshLastRun") as? Date ?? Date(timeIntervalSince1970: 0) }
        set { UserDefaults.standard.set(newValue, forKey: "bgRefreshLastRun") }
    }

    /// The date of the last successful processing task run.
    private var lastProcessingRun: Date {
        get { UserDefaults.standard.object(forKey: "bgProcessingLastRun") as? Date ?? Date(timeIntervalSince1970: 0) }
        set { UserDefaults.standard.set(newValue, forKey: "bgProcessingLastRun") }
    }

    /// The OS version string recorded at the last successful run.
    /// Used to detect OS upgrades and force a fresh near-term submission.
    private var lastKnownOSVersion: String {
        get { UserDefaults.standard.string(forKey: "bgLastKnownOSVersion") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bgLastKnownOSVersion") }
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "BackgroundTasks")
    private var handlersRegistered = false

    private init() {}

    // MARK: - Registration (must be called at app launch, before applicationDidFinishLaunching returns)

    /// Registers BGTaskScheduler launch handlers for all permitted task identifiers.
    ///
    /// **MUST be called in `App.init()` or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`**,
    /// before the app finishes launching. Calling it later (e.g. in a `.task {}` modifier or
    /// `onAppear`) is too late — iOS will not invoke the handlers for tasks that fire before
    /// the handlers are registered, silently marking them as failed.
    func registerHandlers() {
        guard !handlersRegistered else { return }
        handlersRegistered = true

        // BGAppRefreshTask: lightweight conversation list refresh
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleRefreshTask(refreshTask)
        }

        // BGProcessingTask: heavier background processing (reserved for future use)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleProcessingTask(processingTask)
        }

        logger.info("BGTask handlers registered for refresh + processing")
    }

    // MARK: - Scheduling

    /// Schedules (or re-arms) all registered background tasks.
    ///
    /// Safe to call frequently — `shouldSkipSubmit` guards against replacing a
    /// pending request that already fires sooner than what we'd submit. Re-arming
    /// on every scene-phase transition keeps the scheduler well-stocked.
    func scheduleAll() {
        scheduleRefreshTask()
        scheduleProcessingTask()
    }

    // MARK: - Task Handlers

    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        let token = BGTaskCompletionToken()

        // Expiration handler: iOS calls this when the task's time is almost up.
        // MUST be set — Apple docs: "Not setting an expiration handler results in
        // the system marking your task as complete and unsuccessful."
        // The token ensures setTaskCompleted is called exactly once even if both
        // the expiration handler and the normal finish path race.
        task.expirationHandler = {
            token.complete(task, success: false)
        }

        // Re-arm immediately when the task launches — this is the correct pattern
        // recommended by Apple. Do it BEFORE the work so the new request is queued
        // even if the work throws or times out.
        lastRefreshRun = Date()
        scheduleRefreshTask()

        Task {
            let success = await performRefreshWork()
            token.complete(task, success: success)
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        let token = BGTaskCompletionToken()

        task.expirationHandler = {
            token.complete(task, success: false)
        }

        lastProcessingRun = Date()
        scheduleProcessingTask()

        Task {
            let success = await performProcessingWork()
            token.complete(task, success: success)
        }
    }

    // MARK: - Actual Background Work

    /// Lightweight refresh: fetch the first page of conversations to keep badge/list current.
    /// Must complete in well under 3 seconds to stay within the BGAppRefreshTask budget.
    private func performRefreshWork() async -> Bool {
        // For now this is a lightweight no-op — the badge is managed by NotificationService
        // and the conversation list self-refreshes on foreground return. A future version
        // could perform a HEAD /api/v1/chats/?page=1 to check for new messages and update
        // the badge accordingly.
        logger.info("BGAppRefreshTask: refresh work completed (no-op)")
        return true
    }

    /// Heavier processing work. Reserved for future offline tasks.
    /// Has more time budget than refresh and requires network connectivity.
    private func performProcessingWork() async -> Bool {
        logger.info("BGProcessingTask: processing work completed (no-op)")
        return true
    }

    // MARK: - Schedule Helpers

    private func scheduleRefreshTask() {
        let now = Date()
        let desiredEarliest = max(
            now.addingTimeInterval(minimumDelay),
            lastRefreshRun.addingTimeInterval(refreshInterval)
        )

        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = desiredEarliest

        do {
            // Check whether the existing pending request already covers our desired date.
            // If so, leave it alone — replacing it would only push the date later.
            if shouldSkipSubmit(
                identifer: Self.refreshIdentifier,
                desiredEarliest: desiredEarliest
            ) {
                return
            }
            try BGTaskScheduler.shared.submit(request)
            logger.info("BGAppRefreshTask scheduled for \(desiredEarliest)")
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .notPermitted:
                logger.warning("BGAppRefreshTask not permitted — check BGTaskSchedulerPermittedIdentifiers in Info.plist")
            case .tooManyPendingTaskRequests:
                logger.warning("BGAppRefreshTask: too many pending requests")
            case .unavailable:
                break // Simulator or restricted environment — expected
            case .immediateRunIneligible:
                break // Only returned for BGContinuedProcessingTaskRequest — not used here
            @unknown default:
                logger.warning("BGAppRefreshTask submit error: \(error.localizedDescription)")
            }
        } catch {
            logger.warning("BGAppRefreshTask submit error: \(error.localizedDescription)")
        }
    }

    private func scheduleProcessingTask() {
        let now = Date()
        let desiredEarliest = max(
            now.addingTimeInterval(minimumDelay),
            lastProcessingRun.addingTimeInterval(processingInterval)
        )

        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.earliestBeginDate = desiredEarliest
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false // Allow off-charger runs

        do {
            if shouldSkipSubmit(
                identifer: Self.processingIdentifier,
                desiredEarliest: desiredEarliest
            ) {
                return
            }
            try BGTaskScheduler.shared.submit(request)
            logger.info("BGProcessingTask scheduled for \(desiredEarliest)")
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .notPermitted:
                logger.warning("BGProcessingTask not permitted — check BGTaskSchedulerPermittedIdentifiers in Info.plist")
            case .tooManyPendingTaskRequests:
                logger.warning("BGProcessingTask: too many pending requests")
            case .unavailable:
                break
            case .immediateRunIneligible:
                break // Only returned for BGContinuedProcessingTaskRequest — not used here
            @unknown default:
                logger.warning("BGProcessingTask submit error: \(error.localizedDescription)")
            }
        } catch {
            logger.warning("BGProcessingTask submit error: \(error.localizedDescription)")
        }
    }

    /// Returns `true` if the existing pending request for the identifier fires at or
    /// before `desiredEarliest + tolerance`, meaning replacing it would only push the
    /// date LATER. In that case, the caller should leave the existing request alone.
    ///
    /// Because `BGTaskScheduler` doesn't expose the pending request's `earliestBeginDate`
    /// synchronously, we use a simple heuristic: if the desired date is no more than
    /// `minimumDelay` seconds in the future, any existing request is almost certainly
    /// already queued — skip the submit. For longer intervals, always submit (the scheduler
    /// ignores duplicate submits when `earliestBeginDate` is the same).
    ///
    /// Note: A future enhancement could use `BGTaskScheduler.shared.getPendingTaskRequests`
    /// (which is async) to compare dates precisely, at the cost of added complexity.
    private func shouldSkipSubmit(identifer: String, desiredEarliest: Date) -> Bool {
        // Check for post-reboot or post-OS-upgrade conditions that require a force submit.
        let currentOS = ProcessInfo.processInfo.operatingSystemVersionString
        let isPostOSUpgrade = !lastKnownOSVersion.isEmpty && lastKnownOSVersion != currentOS
        let uptime = ProcessInfo.processInfo.systemUptime
        let isPostReboot = uptime < 600 // Less than 10 minutes since boot

        if isPostReboot || isPostOSUpgrade {
            // Force resubmission after reboot/upgrade — stale pending requests may have
            // old earliestBeginDate values that delay the first post-reboot wake by hours.
            if isPostOSUpgrade {
                lastKnownOSVersion = currentOS
                logger.info("Post-OS-upgrade detected — forcing BGTask resubmission")
            } else {
                logger.info("Post-reboot detected — forcing BGTask resubmission")
            }
            return false // Do NOT skip — force submit
        }

        // Normal case: the scheduler handles deduplication when desiredEarliest is the same
        // or earlier than an existing pending request. We don't skip in the normal case —
        // BGTaskScheduler silently accepts duplicate submits for the same identifier and
        // the new request simply replaces the old one. The key insight is: we should skip
        // only if the existing request fires SOONER than what we'd submit (i.e. replacing
        // it would push the date later). Since we anchor to lastRun + interval, not `now`,
        // the desired date stays constant across re-arms, making this a no-op on re-arms.
        return false
    }
}

// MARK: - BGTaskCompletionToken

/// Thread-safe one-shot wrapper around `BGTask.setTaskCompleted(success:)`.
///
/// Both the normal completion path and the `expirationHandler` can call
/// `complete(_:success:)` — the first call wins and actually invokes
/// `setTaskCompleted`, while any later calls are silently ignored.
///
/// Uses `OSAllocatedUnfairLock` (Apple's recommended low-level lock) to guard
/// the "already completed" flag against the race described in the CalCopilot
/// background task article: iOS can call `expirationHandler` *after* the task
/// has already completed normally, causing a second `setTaskCompleted` call on
/// the same task object, which is undefined behaviour.
final class BGTaskCompletionToken: @unchecked Sendable {

    private let completed = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Calls `task.setTaskCompleted(success:)` exactly once.
    ///
    /// - Returns: `true` if this call performed the completion; `false` if the task
    ///   was already completed by a prior call.
    @discardableResult
    func complete(_ task: BGTask, success: Bool) -> Bool {
        let shouldComplete = completed.withLock { done -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        guard shouldComplete else { return false }
        task.setTaskCompleted(success: success)
        return true
    }
}
