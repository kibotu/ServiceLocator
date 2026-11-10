import Foundation

/// A thread-safe registry that creates and hands out your app's services.
///
/// Registrations are keyed by the exact type you pass, so register protocols as
/// `single(Repository.self) { ... }` and resolve them as `Repository`.
///
/// Factories run outside any lock, so independent singletons initialize in parallel in ``build()``.
/// A factory that resolves a singleton another thread is still creating waits for just that one.
public final class ServiceLocator: @unchecked Sendable {
    /// Receives diagnostics: registrations, every resolve with its call site, builds and failures.
    /// The message is built lazily, so a logger that checks a runtime flag first costs nothing when off:
    /// `{ message in if debugFlag { os_log("\(message())") } }`.
    public typealias Logger = @Sendable (_ message: () -> String) -> Void

    /// A ready-made ``Logger`` that prints.
    public static let printLogger: Logger = { print("[ServiceLocator] \($0())") }

    private struct Registration {
        let make: () -> Any
        let isSingleton: Bool
        let onMainActor: Bool
    }

    // A registration is keyed by its type and, optionally, a string identifier.
    private struct Key: Hashable, CustomStringConvertible {
        let type: ObjectIdentifier
        let name: String
        let identifier: String?

        init(_ type: Any.Type, _ identifier: String?) {
            self.type = ObjectIdentifier(type)
            self.name = "\(type)"
            self.identifier = identifier
        }

        static func == (lhs: Key, rhs: Key) -> Bool { lhs.type == rhs.type && lhs.identifier == rhs.identifier }
        func hash(into hasher: inout Hasher) {
            hasher.combine(type)
            hasher.combine(identifier)
        }

        var description: String { identifier.map { "\(name) (identifier: \"\($0)\")" } ?? name }
    }

    private enum Slot {
        case creating(owner: ObjectIdentifier)
        case ready(Any)
    }

    // What a parked thread waits for; edges of the wait-for graph used to detect cycles.
    private enum Wait {
        case singleton(Key)
        case mainThread
    }

    // A main-actor factory queued by a background thread. Fields are guarded by `condition`.
    private final class MainJob {
        let key: Key
        let registration: Registration
        let waiter: ObjectIdentifier
        var value: Any?
        var abandoned = false

        init(key: Key, registration: Registration, waiter: ObjectIdentifier) {
            self.key = key
            self.registration = registration
            self.waiter = waiter
        }
    }

    private static let mainThread = ObjectIdentifier(Thread.main)

    // Guards everything below; `wait()` parks threads until a singleton or main-thread job completes.
    private let condition = NSCondition()
    private let logger: Logger?
    private let waitTimeout: TimeInterval?
    private var registrations: [Key: Registration] = [:]
    private var singletonKeys: [Key] = []
    private var slots: [Key: Slot] = [:]
    private var waits: [ObjectIdentifier: Wait] = [:]
    private var activeFactories: [ObjectIdentifier: [Key]] = [:]
    private var mainJobs: [MainJob] = []

    /// - Parameters:
    ///   - logger: Receives diagnostics; `nil` (default) disables logging.
    ///   - waitTimeout: How long a resolve waits for a singleton another thread is creating, or for
    ///     the main thread to run an `onMainActor` factory, before throwing ``ResolutionError/timedOut(type:)``.
    ///     `nil` waits forever.
    public init(logger: Logger? = nil, waitTimeout: TimeInterval? = 10) {
        self.logger = logger
        self.waitTimeout = waitTimeout
    }

    /// Registers a factory that creates a new instance on every resolve.
    /// Registering a type twice is a programmer error and traps.
    ///
    /// - Parameter onMainActor: Runs the factory on the main thread, even when resolved from another
    ///   one (inline if already on main). In Swift 6 call main-actor initializers via `MainActor.assumeIsolated { }`.
    public func factory<T>(_ type: T.Type = T.self, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        register(Key(type, nil), Registration(make: { factory() }, isSingleton: false, onMainActor: onMainActor))
    }

    /// Registers a factory under a string identifier, so several registrations of the same type can coexist.
    /// Resolve it with ``resolve(_:identifier:file:fileID:function:line:)``.
    public func factory<T>(_ type: T.Type = T.self, identifier: String, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        register(Key(type, identifier), Registration(make: { factory() }, isSingleton: false, onMainActor: onMainActor))
    }

    /// Registers a singleton, created on first resolve or by ``build()``, whichever comes first.
    /// Registering a type twice is a programmer error and traps.
    ///
    /// - Parameter onMainActor: Runs the factory on the main thread, even when ``build()`` or a resolve
    ///   comes from another one (inline if already on main). See ``factory(_:onMainActor:_:)``.
    public func single<T>(_ type: T.Type = T.self, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        register(Key(type, nil), Registration(make: { factory() }, isSingleton: true, onMainActor: onMainActor))
    }

    /// Registers a singleton under a string identifier. See ``factory(_:identifier:onMainActor:_:)``.
    public func single<T>(_ type: T.Type = T.self, identifier: String, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        register(Key(type, identifier), Registration(make: { factory() }, isSingleton: true, onMainActor: onMainActor))
    }

    /// Registers everything the module declares in ``ServiceLocatorModule/build()``.
    public func module(_ module: () -> ServiceLocatorModule) {
        let module = module()
        module.locator = self
        module.build()
    }

    /// Resolves an instance of `T`. `file`, `fileID`, `function` and `line` identify the requester in logs.
    /// - Throws: ``ResolutionError`` if `T` is not registered, depends on itself, or waiting for it timed out.
    public func resolve<T>(
        _ type: T.Type = T.self,
        file: StaticString = #filePath,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) throws -> T {
        try resolve(type, site: .literal(file: file, fileID: fileID, function: function, line: line))
    }

    /// Resolves the instance of `T` registered under `identifier`.
    /// - Throws: ``ResolutionError`` if nothing is registered under that identifier, it depends on itself, or waiting for it timed out.
    public func resolve<T>(
        _ type: T.Type = T.self,
        identifier: String,
        file: StaticString = #filePath,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) throws -> T {
        try resolve(type, identifier: identifier, site: .literal(file: file, fileID: fileID, function: function, line: line))
    }

    /// Source-compatible form of ``resolve(_:file:fileID:function:line:)``; `T` is inferred from the result.
    public func resolve<T>(_ file: String, _ fileId: String, _ function: String, _ line: Int) throws -> T {
        try resolve(T.self, site: .dynamic(file: file, fileID: fileId, function: function, line: UInt(clamping: line)))
    }

    func resolve<T>(_ type: T.Type, identifier: String? = nil, site: Site) throws -> T {
        let key = Key(type, identifier)
        log("resolve \(key) by \(site)")
        do {
            return try instance(of: key) as! T
        } catch {
            log("failed to resolve \(key) by \(site): \(error)")
            throw error
        }
    }

    /// Creates all registered singletons in parallel, so misconfiguration surfaces at launch rather
    /// than on first use. Each singleton waits only for the dependencies its factory resolves.
    /// Factories run on background threads, except `onMainActor` ones, which need the main thread
    /// to be free or waiting on this locator. Singletons that already exist are kept.
    /// Traps if a factory cannot resolve a dependency.
    public func build() async {
        let keys = condition.withLock { singletonKeys }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                DispatchQueue.concurrentPerform(iterations: keys.count) { index in
                    let key = keys[index]
                    log("build \(key)")
                    do {
                        _ = try instance(of: key)
                    } catch {
                        fatalError("Failed to build \(key): \(error)")
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Removes all registrations and singleton instances. Don't call while ``build()`` is running.
    public func reset() {
        condition.withLock {
            registrations.removeAll()
            singletonKeys.removeAll()
            slots.removeAll()
        }
        log("reset")
    }

    // For non-throwing call sites, where a missing registration is a programmer error.
    func resolveOrTrap<T>(_ type: T.Type, identifier: String? = nil, site: Site) -> T {
        do {
            return try resolve(type, identifier: identifier, site: site)
        } catch {
            site.trap("Failed to resolve \(Key(type, identifier)) for \(site): \(error)")
        }
    }

    private func register(_ key: Key, _ registration: Registration) {
        condition.withLock {
            precondition(registrations[key] == nil, "\(key) is already registered")
            registrations[key] = registration
            if registration.isSingleton { singletonKeys.append(key) }
        }
        log("register \(key)")
    }

    private func instance(of key: Key) throws -> Any {
        condition.lock()
        if case .ready(let value)? = slots[key] {
            condition.unlock()
            return value
        }

        let thread = ObjectIdentifier(Thread.current)
        let deadline = waitTimeout.map { Date(timeIntervalSinceNow: $0) }
        while true {
            switch slots[key] {
            case .ready(let value):
                condition.unlock()
                return value

            case .creating:
                if thread == Self.mainThread, !mainJobs.isEmpty {
                    // What we wait for may need the main thread: serve its queued work instead of blocking it.
                    let job = mainJobs.removeFirst()
                    condition.unlock()
                    run(job)
                    condition.lock()
                } else if wouldDeadlock(.singleton(key), on: thread) {
                    condition.unlock()
                    throw ResolutionError.circularDependency(type: "\(key)")
                } else {
                    waits[thread] = .singleton(key)
                    let signaled = wait(until: deadline)
                    waits[thread] = nil
                    if !signaled, case .creating? = slots[key] {
                        condition.unlock()
                        throw ResolutionError.timedOut(type: "\(key)")
                    }
                }

            case nil:
                guard let registration = registrations[key] else {
                    condition.unlock()
                    throw ResolutionError.notRegistered(type: "\(key)")
                }
                if registration.isSingleton {
                    slots[key] = .creating(owner: thread)
                } else {
                    if activeFactories[thread, default: []].contains(key) {
                        condition.unlock()
                        throw ResolutionError.circularDependency(type: "\(key)")
                    }
                    activeFactories[thread, default: []].append(key)
                }
                condition.unlock()

                let value: Any
                do {
                    value = try create(registration, key: key, thread: thread)
                } catch {
                    condition.withLock {
                        if !registration.isSingleton {
                            popFactory(key, on: thread)
                        } else if case .creating(let owner)? = slots[key], owner == thread {
                            // Never handed to main: release the slot so a later resolve can retry.
                            slots[key] = nil
                            condition.broadcast()
                        }
                    }
                    throw error
                }

                condition.withLock {
                    if registration.isSingleton {
                        slots[key] = .ready(value)
                        condition.broadcast()
                    } else {
                        popFactory(key, on: thread)
                    }
                }
                return value
            }
        }
    }

    private func create(
        _ registration: Registration,
        key: Key,
        thread: ObjectIdentifier
    ) throws -> Any {
        guard registration.onMainActor, thread != Self.mainThread else { return registration.make() }

        // Not DispatchQueue.main.sync: if main is parked waiting on us, it runs this job itself.
        let job = MainJob(key: key, registration: registration, waiter: thread)
        let deadline = waitTimeout.map { Date(timeIntervalSinceNow: $0) }
        condition.withLock {
            mainJobs.append(job)
            waits[thread] = .mainThread
            condition.broadcast()
        }
        DispatchQueue.main.async { [self] in runMainJobs() }

        condition.lock()
        defer { condition.unlock() }
        while job.value == nil {
            if !wait(until: deadline), job.value == nil {
                job.abandoned = true
                waits[thread] = nil
                mainJobs.removeAll { $0 === job }
                throw ResolutionError.timedOut(type: "\(key)")
            }
        }
        return job.value!
    }

    private func runMainJobs() {
        while let job = condition.withLock({ mainJobs.isEmpty ? nil : mainJobs.removeFirst() }) { run(job) }
    }

    // Runs on main. Finishes on the waiter's behalf before it wakes, so no one sees a stale wait-for edge.
    private func run(_ job: MainJob) {
        let isSingleton = job.registration.isSingleton
        let started = condition.withLock {
            guard !job.abandoned else { return false }
            if isSingleton {
                slots[job.key] = .creating(owner: Self.mainThread)
            } else {
                activeFactories[Self.mainThread, default: []].append(job.key)
            }
            return true
        }
        guard started else { return }

        let value = job.registration.make()
        condition.withLock {
            if isSingleton {
                slots[job.key] = .ready(value)
            } else {
                popFactory(job.key, on: Self.mainThread)
            }
            if !job.abandoned { waits[job.waiter] = nil }
            job.value = value
            condition.broadcast()
        }
    }

    // Callers must hold `condition`. Returns false on timeout.
    private func wait(until deadline: Date?) -> Bool {
        guard let deadline else {
            condition.wait()
            return true
        }
        return condition.wait(until: deadline)
    }

    // Callers must hold `condition`.
    private func popFactory(_ key: Key, on thread: ObjectIdentifier) {
        activeFactories[thread]?.removeLast()
        if activeFactories[thread]?.isEmpty == true { activeFactories[thread] = nil }
    }

    // Walks the wait-for graph from `wait`; reaching `thread` means waiting would never end.
    // Callers must hold `condition`.
    private func wouldDeadlock(_ wait: Wait, on thread: ObjectIdentifier) -> Bool {
        var wait = wait
        var visited: Set<ObjectIdentifier> = []
        while true {
            let owner: ObjectIdentifier
            switch wait {
            case .singleton(let key):
                guard case .creating(let creator)? = slots[key] else { return false }
                owner = creator
            case .mainThread:
                // Queued main jobs get run by main, whether it is idle or parked in this locator.
                guard mainJobs.isEmpty else { return false }
                owner = Self.mainThread
            }
            if owner == thread { return true }
            guard visited.insert(owner).inserted, let next = waits[owner] else { return false }
            wait = next
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        logger?(message)
    }
}

/// Creates a `ServiceLocator`, optionally registering a root module (which can nest others via `module { }`).
/// Call ``ServiceLocator/build()`` afterwards to create singletons eagerly and in parallel.
public func startServiceLocator(_ module: (() -> ServiceLocatorModule)? = nil) -> ServiceLocator {
    startServiceLocator(logger: nil, module)
}

/// Same, configured; see ``ServiceLocator/init(logger:waitTimeout:)``.
public func startServiceLocator(
    logger: ServiceLocator.Logger?,
    waitTimeout: TimeInterval? = 10,
    _ module: (() -> ServiceLocatorModule)? = nil
) -> ServiceLocator {
    let locator = ServiceLocator(logger: logger, waitTimeout: waitTimeout)
    if let module { locator.module(module) }
    return locator
}
