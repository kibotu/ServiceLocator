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

    private enum Slot {
        case creating(owner: ObjectIdentifier)
        case ready(Any)
    }

    // What a parked thread waits for; edges of the wait-for graph used to detect cycles.
    private enum Wait {
        case singleton(ObjectIdentifier)
        case mainThread
    }

    private static let mainThread = ObjectIdentifier(Thread.main)

    // Guards everything below; `wait()` parks threads until a singleton or main-thread job completes.
    private let condition = NSCondition()
    private let logger: Logger?
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var singletonTypes: [Any.Type] = []
    private var slots: [ObjectIdentifier: Slot] = [:]
    private var waits: [ObjectIdentifier: Wait] = [:]
    private var activeFactories: [ObjectIdentifier: [ObjectIdentifier]] = [:]
    private var mainJobs: [() -> Void] = []

    /// - Parameter logger: Receives diagnostics; `nil` (default) disables logging.
    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Registers a factory that creates a new instance on every resolve.
    /// Registering a type twice is a programmer error and traps.
    ///
    /// - Parameter onMainActor: Runs the factory on the main thread, even when resolved from another
    ///   one (inline if already on main). In Swift 6 call main-actor initializers via `MainActor.assumeIsolated { }`.
    public func factory<T>(_ type: T.Type = T.self, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        register(type, Registration(make: { factory() }, isSingleton: false, onMainActor: onMainActor))
    }

    /// Registers a singleton, created on first resolve or by ``build()``, whichever comes first.
    /// Registering a type twice is a programmer error and traps.
    ///
    /// - Parameter onMainActor: Runs the factory on the main thread, even when ``build()`` or a resolve
    ///   comes from another one (inline if already on main). See ``factory(_:onMainActor:_:)``.
    public func single<T>(_ type: T.Type = T.self, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        register(type, Registration(make: { factory() }, isSingleton: true, onMainActor: onMainActor))
    }

    /// Registers everything the module declares in ``ServiceLocatorModule/build()``.
    public func module(_ module: () -> ServiceLocatorModule) {
        let module = module()
        module.locator = self
        module.build()
    }

    /// Resolves an instance of `T`. `fileID`, `function` and `line` identify the requester in logs.
    /// - Throws: ``ResolutionError`` if `T` is not registered or depends on itself.
    public func resolve<T>(
        _ type: T.Type = T.self,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) throws -> T {
        log("resolve \(type) by \(fileID)#\(function):\(line)")
        do {
            return try instance(of: type) as! T
        } catch {
            log("failed to resolve \(type) by \(fileID)#\(function):\(line): \(error)")
            throw error
        }
    }

    /// Creates all registered singletons in parallel, so misconfiguration surfaces at launch rather
    /// than on first use. Each singleton waits only for the dependencies its factory resolves.
    /// Factories run on background threads, except `onMainActor` ones, which need the main thread
    /// to be free or waiting on this locator. Singletons that already exist are kept.
    /// Traps if a factory cannot resolve a dependency.
    public func build() async {
        let types = condition.withLock { singletonTypes }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                DispatchQueue.concurrentPerform(iterations: types.count) { index in
                    let type = types[index]
                    log("build \(type)")
                    do {
                        _ = try instance(of: type)
                    } catch {
                        fatalError("Failed to build \(type): \(error)")
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
            singletonTypes.removeAll()
            slots.removeAll()
        }
        log("reset")
    }

    // For non-throwing call sites, where a missing registration is a programmer error.
    func resolveOrTrap<T>(_ type: T.Type, fileID: StaticString, function: StaticString, line: UInt) -> T {
        do {
            return try resolve(type, fileID: fileID, function: function, line: line)
        } catch {
            fatalError("Failed to resolve \(type) for \(fileID)#\(function): \(error)", file: fileID, line: line)
        }
    }

    private func register<T>(_ type: T.Type, _ registration: Registration) {
        condition.withLock {
            let key = ObjectIdentifier(type)
            precondition(registrations[key] == nil, "\(type) is already registered")
            registrations[key] = registration
            if registration.isSingleton { singletonTypes.append(type) }
        }
        log("register \(type)")
    }

    private func instance(of type: Any.Type) throws -> Any {
        let key = ObjectIdentifier(type)
        condition.lock()
        if case .ready(let value)? = slots[key] {
            condition.unlock()
            return value
        }

        let thread = ObjectIdentifier(Thread.current)
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
                    job()
                    condition.lock()
                } else if wouldDeadlock(.singleton(key), on: thread) {
                    condition.unlock()
                    throw ResolutionError.circularDependency(type: "\(type)")
                } else {
                    waits[thread] = .singleton(key)
                    condition.wait()
                    waits[thread] = nil
                }

            case nil:
                guard let registration = registrations[key] else {
                    condition.unlock()
                    throw ResolutionError.notRegistered(type: "\(type)")
                }
                if registration.isSingleton {
                    slots[key] = .creating(owner: thread)
                } else {
                    if activeFactories[thread, default: []].contains(key) {
                        condition.unlock()
                        throw ResolutionError.circularDependency(type: "\(type)")
                    }
                    activeFactories[thread, default: []].append(key)
                }
                condition.unlock()

                let value = create(registration, key: key, thread: thread)

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

    private func create(_ registration: Registration, key: ObjectIdentifier, thread: ObjectIdentifier) -> Any {
        guard registration.onMainActor, thread != Self.mainThread else { return registration.make() }

        // Not DispatchQueue.main.sync: if main is parked waiting on us, it runs this job itself.
        final class Result { var value: Any? }
        let result = Result()
        let job = { [self] in
            condition.withLock {
                if registration.isSingleton {
                    slots[key] = .creating(owner: Self.mainThread)
                } else {
                    activeFactories[Self.mainThread, default: []].append(key)
                }
            }
            let value = registration.make()
            // Finish on the waiter's behalf before it wakes, so no one sees a stale wait-for edge.
            condition.withLock {
                if registration.isSingleton {
                    slots[key] = .ready(value)
                } else {
                    popFactory(key, on: Self.mainThread)
                }
                waits[thread] = nil
                result.value = value
                condition.broadcast()
            }
        }

        condition.withLock {
            mainJobs.append(job)
            waits[thread] = .mainThread
            condition.broadcast()
        }
        DispatchQueue.main.async { [self] in runMainJobs() }

        condition.lock()
        while result.value == nil { condition.wait() }
        condition.unlock()
        return result.value!
    }

    private func runMainJobs() {
        while let job = condition.withLock({ mainJobs.isEmpty ? nil : mainJobs.removeFirst() }) { job() }
    }

    // Callers must hold `condition`.
    private func popFactory(_ key: ObjectIdentifier, on thread: ObjectIdentifier) {
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

/// Same, with a ``ServiceLocator/Logger`` that receives registrations, resolves and failures.
public func startServiceLocator(
    logger: ServiceLocator.Logger?,
    _ module: (() -> ServiceLocatorModule)? = nil
) -> ServiceLocator {
    let locator = ServiceLocator(logger: logger)
    if let module { locator.module(module) }
    return locator
}
