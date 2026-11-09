import Foundation

/// A thread-safe registry that creates and hands out your app's services.
///
/// Registrations are keyed by the exact type you pass, so register protocols as
/// `single(Repository.self) { ... }` and resolve them as `Repository`.
///
/// Factories run outside any lock, so independent singletons initialize in parallel in ``build()``.
/// A factory that resolves a singleton another thread is still creating waits for just that one.
public final class ServiceLocator: @unchecked Sendable {
    private enum Registration {
        case factory(() -> Any)
        case singleton(() -> Any)
    }

    private enum Slot {
        case creating(owner: ObjectIdentifier)
        case ready(Any)
    }

    // Guards everything below; `wait()` parks threads that need a singleton still being created.
    private let condition = NSCondition()
    private let logger: Logger?
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var singletonTypes: [Any.Type] = []
    private var slots: [ObjectIdentifier: Slot] = [:]
    private var waitingOn: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var activeFactories: [ObjectIdentifier: [ObjectIdentifier]] = [:]

    /// Receives diagnostics: registrations, every resolve with its call site, builds and failures.
    /// The message is built lazily, so a logger that checks a runtime flag first costs nothing when off:
    /// `{ message in if debugFlag { os_log("\(message())") } }`.
    public typealias Logger = @Sendable (_ message: () -> String) -> Void

    /// A ready-made ``Logger`` that prints.
    public static let printLogger: Logger = { print("[ServiceLocator] \($0())") }

    /// - Parameter logger: Receives diagnostics; `nil` (default) disables logging.
    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Registers a factory that creates a new instance on every resolve.
    /// Registering a type twice is a programmer error and traps.
    public func factory<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        register(type, .factory { factory() })
    }

    /// Registers a singleton, created on first resolve or by ``build()``, whichever comes first.
    /// Registering a type twice is a programmer error and traps.
    public func single<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        register(type, .singleton { factory() }, isSingleton: true)
    }

    /// Registers everything the module declares in ``ServiceLocatorModule/build()``.
    public func module(_ module: () -> ServiceLocatorModule) {
        let module = module()
        module.locator = self
        module.build()
    }

    /// Resolves an instance of `T`.
    /// - Throws: ``ResolutionError`` if `T` is not registered or depends on itself.
    /// `fileID`, `function` and `line` identify the requester and show up in logs.
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
    /// Factories run on background threads. Singletons that already exist are kept.
    /// Traps if a factory cannot resolve a dependency.
    public func build() async {
        let types = condition.withLock { singletonTypes }
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            for type in types {
                DispatchQueue.global().async(group: group) { [self] in
                    log("build \(type)")
                    do {
                        _ = try instance(of: type)
                    } catch {
                        fatalError("Failed to build \(type): \(error)")
                    }
                }
            }
            group.notify(queue: .global()) { continuation.resume() }
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

    private func register<T>(_ type: T.Type, _ registration: Registration, isSingleton: Bool = false) {
        condition.withLock {
            let key = ObjectIdentifier(type)
            precondition(registrations[key] == nil, "\(type) is already registered")
            registrations[key] = registration
            if isSingleton { singletonTypes.append(type) }
        }
        log("register \(type)")
    }

    private func instance(of type: Any.Type) throws -> Any {
        let key = ObjectIdentifier(type)
        let thread = ObjectIdentifier(Thread.current)
        condition.lock()
        while true {
            switch slots[key] {
            case .ready(let value):
                condition.unlock()
                return value

            case .creating:
                if wouldDeadlock(waitingFor: key, on: thread) {
                    condition.unlock()
                    throw ResolutionError.circularDependency(type: "\(type)")
                }
                waitingOn[thread] = key
                condition.wait()
                waitingOn[thread] = nil

            case nil:
                guard let registration = registrations[key] else {
                    condition.unlock()
                    throw ResolutionError.notRegistered(type: "\(type)")
                }
                switch registration {
                case .factory(let make):
                    if activeFactories[thread, default: []].contains(key) {
                        condition.unlock()
                        throw ResolutionError.circularDependency(type: "\(type)")
                    }
                    activeFactories[thread, default: []].append(key)
                    condition.unlock()

                    let value = make()

                    condition.withLock {
                        activeFactories[thread]?.removeLast()
                        if activeFactories[thread]?.isEmpty == true { activeFactories[thread] = nil }
                    }
                    return value

                case .singleton(let make):
                    slots[key] = .creating(owner: thread)
                    condition.unlock()

                    let value = make()

                    condition.withLock {
                        slots[key] = .ready(value)
                        condition.broadcast()
                    }
                    return value
                }
            }
        }
    }

    // Follows "thread waits for singleton owned by thread" edges; reaching `thread` means a cycle.
    // Callers must hold `condition`.
    private func wouldDeadlock(waitingFor key: ObjectIdentifier, on thread: ObjectIdentifier) -> Bool {
        var key = key
        while case .creating(let owner)? = slots[key] {
            if owner == thread { return true }
            guard let next = waitingOn[owner] else { return false }
            key = next
        }
        return false
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
