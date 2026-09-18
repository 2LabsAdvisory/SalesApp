import LocalAuthentication
import Network
import Observation
import UIKit

/// Where the app is: signed out, choosing an org, or in.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        /// Someone in more than one organization picks where to work (FR12's
        /// picker). Pre-selected on the one they used last.
        case choosingOrganization
        case signedIn
    }

    private(set) var phase: Phase = .launching
    private(set) var credentials: Credentials?
    private(set) var organizations: [Organization] = []
    private(set) var isOnline = true

    /// The Face ID gate on resume (FR15 §3.3): on by default, can be turned
    /// off. It guards reading the app. It never stands between Siri and a note.
    private(set) var isLocked = false
    /// The system prompt is offered once per lock, on its own. Cancelling it
    /// leaves the lock screen and its Unlock button — asking again every time
    /// the app becomes active would loop, because the prompt itself makes the
    /// app inactive and then active again.
    private var hasPromptedThisLock = false
    var requiresUnlock: Bool {
        didSet { UserDefaults.standard.set(requiresUnlock, forKey: Self.unlockKey) }
    }
    private static let unlockKey = "requiresUnlockOnResume"

    let services: AppServices
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init(services: AppServices = .shared) {
        self.services = services
        requiresUnlock = UserDefaults.standard.object(forKey: Self.unlockKey) as? Bool ?? true
    }

    // MARK: Launch

    func start() async {
        observers.append(NotificationCenter.default.addObserver(
            forName: TokenStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.credentialsChanged() }
        })
        watchConnectivity()

        credentials = await services.tokens.current()
        if credentials == nil {
            phase = .signedOut
        } else {
            if requiresUnlock { lock() }
            phase = .signedIn
            Task { await refreshProfile() }
        }
        await services.sender.reconcile()
        #if DEBUG
        await captureFromLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Development only: `-SalesCaptureOnLaunch "text"` captures a note through
    /// the same path as Siri and the mic, so the queue and the sender can be
    /// exercised in the simulator, which cannot recognize speech on-device.
    private func captureFromLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SalesCaptureOnLaunch"), index + 1 < arguments.count else { return }
        _ = try? await services.capture.capture(arguments[index + 1], source: .appRecorder)
    }
    #endif

    /// Picks up a sign-out from anywhere — a revoked device found by the
    /// sender at 3am is still a sign-out.
    private func credentialsChanged() async {
        credentials = await services.tokens.current()
        if credentials == nil, phase != .launching {
            phase = .signedOut
            isLocked = false
        }
    }

    private func watchConnectivity() {
        pathMonitor.pathUpdateHandler = Self.pathHandler(for: self)
        pathMonitor.start(queue: DispatchQueue(label: "ca.2labs.sales.path"))
    }

    private func pathChanged(online: Bool) async {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { await services.sender.pump() }
    }

    /// Called on the monitor's own queue, so built outside the main actor:
    /// a closure written inside this class would trap there.
    nonisolated private static func pathHandler(for owner: AppModel) -> @Sendable (NWPath) -> Void {
        { [weak owner] path in
            let online = path.status == .satisfied
            Task { @MainActor in await owner?.pathChanged(online: online) }
        }
    }

    // MARK: Signing in

    var thisDevice: DeviceDescription {
        DeviceDescription(name: UIDevice.current.name)
    }

    /// After either door: keep the tokens, learn who and where we are, and
    /// hand any note said before signing in to this person.
    func completeSignIn(with bundle: TokenBundle) async throws {
        try await services.tokens.save(Credentials(bundle: bundle))
        let me = try await services.api.me()
        try await adopt(me)
        organizations = me.organizations
        isLocked = false
        phase = me.organizations.count > 1 ? .choosingOrganization : .signedIn
        await services.sender.pump()
    }

    private func adopt(_ me: MeResponse) async throws {
        try await services.tokens.update {
            $0.userId = me.user.id
            $0.userName = me.user.displayName
            $0.userEmail = me.user.email
            $0.organizationId = me.organization.id
            $0.organizationName = me.organization.name
        }
        try await services.queue.adoptUnowned(
            userId: me.user.id, organizationId: me.organization.id, organizationName: me.organization.name)
        credentials = await services.tokens.current()
    }

    func refreshProfile() async {
        guard let me = try? await services.api.me() else { return }
        try? await adopt(me)
        organizations = me.organizations
    }

    /// Switching is checked on the server against this person's memberships;
    /// the server also moves the device, so the next refresh stays here.
    func choose(_ organization: Organization) async throws {
        if organization.id != credentials?.organizationId {
            try await services.api.switchOrganization(to: organization.id)
            try await services.tokens.update {
                $0.organizationId = organization.id
                $0.organizationName = organization.name
            }
            credentials = await services.tokens.current()
        }
        phase = .signedIn
    }

    func signOut() async {
        await services.api.signOut()
        credentials = nil
        organizations = []
        isLocked = false
        phase = .signedOut
    }

    // MARK: The gate

    func sceneMovedToBackground() {
        if phase == .signedIn, requiresUnlock { lock() }
    }

    private func lock() {
        isLocked = true
        hasPromptedThisLock = false
    }

    /// Offered by the lock screen when the app becomes active: prompts once.
    func unlockAutomatically() async {
        guard isLocked, !hasPromptedThisLock else { return }
        hasPromptedThisLock = true
        await unlock()
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        // Face ID, falling back to the passcode — a phone with neither has no
        // lock to borrow, and the gate stands aside.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Sales")) == true {
            isLocked = false
        }
    }
}
