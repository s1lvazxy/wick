import AppKit
import Observation
import ServiceManagement
import UserNotifications
import WickCore

@Observable
public final class WickModel {
    public enum Phase: Equatable {
        case idle
        case awake(Session)
        case awakeElsewhere
    }

    public static let minimumMinutes = 5.0
    public static let maximumMinutes = 720.0
    public static let repositoryURL = URL(string: "https://github.com/s1lvazxy/wick")!

    public var phase: Phase = .idle
    public var minutes: Double
    public var isForever: Bool
    /// Live value while the ruler is being dragged or is settling. Nil the rest of the time.
    public var scrubMinutes: Double?
    public var stopWhenAgentsFinish: Bool
    public var batteryFloor: Int?
    public var agents: [String] = []
    public var battery: Battery?
    public var heat = Heat(level: .nominal, isLidClosed: nil, batteryCelsius: nil)
    public var needsAccess = false
    public var isBusy = false
    public var problem: String?
    public var lastEnd: SessionEnd?
    public var showsTimeInMenuBar: Bool
    public var opensAtLogin = false

    /// Called after any change the menu bar item has to reflect.
    public var statusDidChange: (() -> Void)?

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private let store = SessionStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var panelIsOpen = false
    @ObservationIgnored private var hasAskedForNotifications = false
    @ObservationIgnored private var hasReadOnce = false

    public var isAwake: Bool { phase != .idle }

    public var session: Session? {
        if case .awake(let session) = phase { session } else { nil }
    }

    public init(live: Bool = true) {
        isLive = live
        minutes = defaults.object(forKey: "minutes") as? Double ?? 120
        isForever = defaults.bool(forKey: "forever")
        stopWhenAgentsFinish = defaults.bool(forKey: "agents")
        batteryFloor = defaults.object(forKey: "batteryFloor").map { $0 as? Int ?? 20 } ?? 20
        if defaults.object(forKey: "batteryFloorOff") as? Bool == true { batteryFloor = nil }
        showsTimeInMenuBar = defaults.object(forKey: "showsTime") as? Bool ?? true
        if live { opensAtLogin = SMAppService.mainApp.status == .enabled }
    }

    public func remaining(at date: Date) -> TimeInterval? {
        guard let endsAt = session?.endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(date))
    }

    // MARK: Live state

    public func beginRefreshing() {
        guard isLive else { return }
        let executable = Self.guardExecutable
        Task {
            await Self.reconcile(executable)
            restartRefreshLoop()
        }
    }

    public func panelVisibilityChanged(_ isOpen: Bool) {
        panelIsOpen = isOpen
        if !isOpen { needsAccess = false; problem = nil }
        if isLive { restartRefreshLoop() }
    }

    private func restartRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let interval: Duration = self.panelIsOpen ? .seconds(2) : .seconds(10)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refresh() async {
        let reading = await Self.read(store, includingAgents: panelIsOpen)
        apply(reading)
    }

    private func apply(_ reading: Reading) {
        if let session = reading.session, reading.isAwake {
            phase = .awake(session)
        } else {
            phase = reading.isAwake ? .awakeElsewhere : .idle
        }
        if let agents = reading.agents { self.agents = agents }
        battery = reading.battery
        heat = reading.heat
        if reading.lastEnd != lastEnd {
            lastEnd = reading.lastEnd
            // Nobody is watching when these happen. Anything else, the person just did themselves.
            if hasReadOnce, let end = reading.lastEnd,
               [.timeUp, .agentsFinished, .lowBattery, .overheating].contains(end.reason) {
                notify(end)
            }
        }
        hasReadOnce = true
        statusDidChange?()
    }

    private struct Reading: Sendable {
        var isAwake: Bool
        var session: Session?
        var lastEnd: SessionEnd?
        var agents: [String]?
        var battery: Battery?
        var heat: Heat
    }

    /// Scanning every process is only worth it while someone can see the result.
    @concurrent private static func read(_ store: SessionStore, includingAgents: Bool) async -> Reading {
        Reading(
            isAwake: Power.sleepDisabled() ?? false,
            session: store.load(),
            lastEnd: store.lastEnd(),
            agents: includingAgents ? Agents.running() : nil,
            battery: Battery.current(),
            heat: Heat.current()
        )
    }

    @concurrent private static func reconcile(_ executable: URL) async {
        Wick.reconcile(guardExecutable: executable)
    }

    /// Inside the app bundle in production, next to the app binary under `swift run`.
    private static var guardExecutable: URL {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/wick")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(filePath: Bundle.main.executablePath ?? "").deletingLastPathComponent().appending(path: "wick")
    }

    // MARK: Actions

    public func toggle() {
        guard isLive, !isBusy else { return }
        if isAwake { stop() } else { start() }
    }

    private func start() {
        isBusy = true
        problem = nil
        let session = makeSession()
        let executable = Self.guardExecutable
        Task {
            defer { isBusy = false }
            do {
                guard await Self.isAuthorized() else {
                    needsAccess = true
                    return
                }
                try await Self.start(session, executable)
                phase = .awake(session)
                statusDidChange?()
                askForNotificationsOnce()
            } catch {
                problem = "Couldn't turn sleep off. \(Self.describe(error))"
            }
        }
    }

    private func stop() {
        isBusy = true
        problem = nil
        Task {
            defer { isBusy = false }
            do {
                try await Self.stop()
                phase = .idle
                lastEnd = SessionEnd(reason: .stoppedByUser)
                statusDidChange?()
            } catch PowerError.notAuthorized {
                needsAccess = true
            } catch {
                problem = "Couldn't turn sleep back on. \(Self.describe(error))"
            }
        }
    }

    public func allowAccess() {
        guard isLive, !isBusy else { return }
        isBusy = true
        problem = nil
        Task {
            do {
                try await Self.installAccess()
                needsAccess = false
                isBusy = false
                toggle()
            } catch AccessError.cancelled {
                isBusy = false
            } catch {
                isBusy = false
                problem = "Couldn't add the permission. \(Self.describe(error))"
            }
        }
    }

    public func dismissAccess() {
        needsAccess = false
    }

    public func removeAccess() {
        guard isLive, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await Self.removeAccess()
                await refresh()
            } catch AccessError.cancelled {
                // Nothing changed, nothing to report.
            } catch {
                problem = "Couldn't remove the permission. \(Self.describe(error))"
            }
        }
    }

    private func makeSession() -> Session {
        Session(
            endsAt: isForever ? nil : Date.now.addingTimeInterval(minutes * 60),
            untilAgentsFinish: stopWhenAgentsFinish,
            batteryFloor: batteryFloor
        )
    }

    // MARK: Ruler and settings

    public func scrub(to minutes: Double) {
        scrubMinutes = minutes
    }

    public func commitDuration(_ minutes: Double, forever: Bool = false) {
        self.minutes = minutes
        isForever = forever
        defaults.set(minutes, forKey: "minutes")
        defaults.set(forever, forKey: "forever")
        updateSession { $0.endsAt = forever ? nil : Date.now.addingTimeInterval(minutes * 60) }
    }

    public func scrubEnded() {
        scrubMinutes = nil
    }

    public func setStopWhenAgentsFinish(_ isOn: Bool) {
        stopWhenAgentsFinish = isOn
        defaults.set(isOn, forKey: "agents")
        updateSession { $0.untilAgentsFinish = isOn }
    }

    public func setBatteryFloor(_ floor: Int?) {
        batteryFloor = floor
        defaults.set(floor, forKey: "batteryFloor")
        defaults.set(floor == nil, forKey: "batteryFloorOff")
        updateSession { $0.batteryFloor = floor }
    }

    public func setShowsTimeInMenuBar(_ isOn: Bool) {
        showsTimeInMenuBar = isOn
        defaults.set(isOn, forKey: "showsTime")
        statusDidChange?()
    }

    public func setOpensAtLogin(_ isOn: Bool) {
        guard isLive else { return }
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            opensAtLogin = isOn
        } catch {
            opensAtLogin = SMAppService.mainApp.status == .enabled
            problem = "Couldn't change the login item. \(error.localizedDescription)"
        }
    }

    /// The guard re-reads the file on every tick, so an edit to a running session just works. The file decides:
    /// this view of the session can be seconds old, and writing it back could revive one that has ended.
    private func updateSession(_ change: (inout Session) -> Void) {
        guard session != nil else { return }
        guard isLive else {
            if var session { change(&session); phase = .awake(session) }
            statusDidChange?()
            return
        }
        phase = store.update(change).map { .awake($0) } ?? .idle
        statusDidChange?()
    }

    /// Called from `applicationWillTerminate`. With the icon gone nothing would show that sleep is off.
    public func stopForQuit() {
        guard isLive, session != nil else { return }
        try? Wick.stop()
    }

    // MARK: Notifications

    private func askForNotificationsOnce() {
        guard !hasAskedForNotifications, Bundle.main.bundleIdentifier != nil else { return }
        hasAskedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ end: SessionEnd) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Wick stopped"
        content.body = end.reason.sentence
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: Off the main thread

    @concurrent private static func isAuthorized() async -> Bool { Power.isAuthorized }

    @concurrent private static func start(_ session: Session, _ executable: URL) async throws {
        try Wick.start(session, guardExecutable: executable)
    }

    @concurrent private static func stop() async throws { try Wick.stop() }
    @concurrent private static func installAccess() async throws { try Access.install() }
    @concurrent private static func removeAccess() async throws { try Access.remove() }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as PowerError: error.sentence
        case AccessError.failed(let detail): detail
        default: error.localizedDescription
        }
    }
}

extension WickModel {
    /// A model with fixed state and no side effects, for snapshots.
    public static func preview(
        phase: Phase = .idle,
        minutes: Double = 120,
        forever: Bool = false,
        agents: [String] = [],
        agentsOn: Bool = false,
        battery: Battery? = Battery(percent: 84, isDischarging: false),
        heat: Heat = Heat(level: .nominal, isLidClosed: false, batteryCelsius: 31),
        needsAccess: Bool = false,
        lastEnd: SessionEnd? = nil,
        problem: String? = nil
    ) -> WickModel {
        let model = WickModel(live: false)
        model.phase = phase
        model.minutes = minutes
        model.isForever = forever
        model.agents = agents
        model.stopWhenAgentsFinish = agentsOn
        model.batteryFloor = 20
        model.battery = battery
        model.heat = heat
        model.needsAccess = needsAccess
        model.lastEnd = lastEnd
        model.problem = problem
        return model
    }
}
