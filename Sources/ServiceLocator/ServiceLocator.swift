import Foundation

/// A thread-safe registry that creates and hands out your app's services.
///
/// Registrations are keyed by the exact type you pass, so register protocols as
/// `single(Repository.self) { ... }` and resolve them as `Repository`.
///
/// Factories run while an internal recursive lock is held, which guarantees a singleton is
/// created once. Don't block on another thread that resolves from the same locator inside a factory.
public final class ServiceLocator: @unchecked Sendable {
    private enum Registration {
        case factory(() -> Any)
        case singleton(() -> Any)
    }

    private let lock = NSRecursiveLock()
    private let isLoggingEnabled: Bool
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var singletonTypes: [Any.Type] = []
    private var instances: [ObjectIdentifier: Any] = [:]
    private var resolving: Set<ObjectIdentifier> = []

    /// - Parameter enableLogging: Prints registrations and resolutions, for debugging.
    public init(enableLogging: Bool = false) {
        isLoggingEnabled = enableLogging
    }

    /// Registers a factory that creates a new instance on every resolve.
    /// Registering a type twice is a programmer error and traps.
    public func factory<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        register(type, .factory { factory() })
    }

    /// Registers a singleton, created on first resolve or by ``build()``, whichever comes first.
    /// Registering a type twice is a programmer error and traps.
    public func single<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        lock.withLock { singletonTypes.append(type) }
        register(type, .singleton { factory() })
    }

    /// Registers everything the module declares in ``ServiceLocatorModule/build()``.
    public func module(_ module: () -> ServiceLocatorModule) {
        lock.withLock {
            let module = module()
            module.locator = self
            module.build()
        }
    }

    /// Resolves an instance of `T`.
    /// - Throws: ``ResolutionError`` if `T` is not registered or depends on itself.
    public func resolve<T>(
        _ type: T.Type = T.self,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> T {
        log("resolve \(type) from \(file):\(line)")
        return try lock.withLock { try instance(of: type) as! T }
    }

    /// Creates all registered singletons now, so misconfiguration surfaces at launch rather than
    /// on first use. Singletons that already exist are kept. Traps if a factory cannot resolve a dependency.
    public func build() {
        lock.withLock {
            for type in singletonTypes {
                log("build \(type)")
                do {
                    _ = try instance(of: type)
                } catch {
                    fatalError("Failed to build \(type): \(error)")
                }
            }
        }
    }

    /// Removes all registrations and singleton instances.
    public func reset() {
        lock.withLock {
            registrations.removeAll()
            singletonTypes.removeAll()
            instances.removeAll()
        }
        log("reset")
    }

    private func register<T>(_ type: T.Type, _ registration: Registration) {
        lock.withLock {
            let key = ObjectIdentifier(type)
            precondition(registrations[key] == nil, "\(type) is already registered")
            registrations[key] = registration
        }
        log("register \(type)")
    }

    // Callers must hold `lock`.
    private func instance(of type: Any.Type) throws -> Any {
        let key = ObjectIdentifier(type)
        if let existing = instances[key] { return existing }
        guard let registration = registrations[key] else {
            throw ResolutionError.notRegistered(type: "\(type)")
        }
        guard resolving.insert(key).inserted else {
            throw ResolutionError.circularDependency(type: "\(type)")
        }
        defer { resolving.remove(key) }

        switch registration {
        case .factory(let make):
            return make()
        case .singleton(let make):
            let created = make()
            instances[key] = created
            return created
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        if isLoggingEnabled { print("[ServiceLocator] \(message())") }
    }
}

/// Creates a `ServiceLocator`, optionally registering a root module (which can nest others via `module { }`).
/// Call ``ServiceLocator/build()`` afterwards to create singletons eagerly.
public func startServiceLocator(
    enableLogging: Bool = false,
    _ module: (() -> ServiceLocatorModule)? = nil
) -> ServiceLocator {
    let locator = ServiceLocator(enableLogging: enableLogging)
    if let module { locator.module(module) }
    return locator
}
