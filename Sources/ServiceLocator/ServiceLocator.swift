import Foundation

public class ServiceLocator {

    private var singletonFactories: [String: Any] = [:]
    private var singletons: [String: Any] = [:]
    private var factories: [String: Any] = [:]
    
    private var lock = NSRecursiveLock()

    /// Registers a factory closure that will be used to create an instance of a service.
    /// - Parameter type: The type of the service to register.
    /// - Parameter factory: A closure that returns an instance of the service.
    internal func factory<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        lock.lock()
        defer { lock.unlock() }
        let key = String(describing: type)
        if factories.keys.contains(key) {
            fatalError("[ServiceLocator] factory duplicated key=$key")
        }
        factories[key] = factory
    }
    
    /// Registers a singleton factory closure that will be used to create and cache an instance of a service.
    /// - Parameter type: The type of the singleton service to register.
    /// - Parameter factory: A closure that creates and returns a single instance of the service.
    internal func single<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        lock.lock()
        defer { lock.unlock() }
        let key = String(describing: type)
        if singletonFactories.keys.contains(key) {
            fatalError("[ServiceLocator] single duplicated key=$key")
        }
        singletonFactories[key] = factory
    }
    
    /// Resolves and returns an instance of the requested service if available.
    /// If a singleton is requested it will return the same cached instance on subsequent calls.
    /// - Returns: An instance of the requested service type `T`.
    /// - Throws: A fatal error if no matching factory or singleton is found for the requested service type `T`.
    public func resolve<T>() -> T {
        lock.lock()
        defer { lock.unlock() }
        let key = String(describing: T.self)
        
        if let singleton = singletons[key] as? T {
            return singleton
        } else if let singletonFactory = singletonFactories[key] as? () -> T {
            let builtService = singletonFactory()
            singletons[key] = builtService
            return builtService
        }
        
        if let serviceFactory = factories[key] as? () -> T {
            return serviceFactory()
        }
        
        fatalError("[ServiceLocator] could not resolve \(key)")
    }

    /// Calls a closure containing module setup logic which should register services within this locator using `factory` or `single`.
    /// - Parameter closure: A closure containing module setup logic with `ServiceLocatorModule` configuration methods called inside it.
    internal func module(_ closure: @escaping () -> ServiceLocatorModule) {
        lock.lock()
        defer { lock.unlock() }
        closure().buildInternal(locator: self)
    }
}

open class ServiceLocatorModule {
    public init() {
    }

    fileprivate weak var locator: ServiceLocator!

    open func build() {
        // Method designed to be overridden where one can put registration logic during module building phase
    }
}

public extension ServiceLocatorModule {
    final internal func buildInternal(locator: ServiceLocator) {
        self.locator = locator
        build()
    }

    final func factory<T>(_  type: T.Type = T.self, _ factory: @escaping () -> T) {
        locator.factory(type, factory)
    }

    final func single<T>(_ type: T.Type = T.self, _ factory: @escaping () -> T) {
        locator.single(type, factory)
    }

    final func resolve<T>() -> T {
        locator.resolve()
    }

    final func module(_ closure: @escaping () -> ServiceLocatorModule) {
        locator.module(closure)
    }
}

/// Initializes and configures a new `ServiceLocator` optionally with provided modules configuration closures.
/// - Parameter closure: An optional closure returning one or more configured modules.
/// - Returns : A fully initialized `ServiceLocator` object ready to use in your application.
public func startServiceLocator(_ closure: (() -> ServiceLocatorModule)? = nil) -> ServiceLocator {
    let serviceLocator = ServiceLocator()
    if let modules = closure?() {
        serviceLocator.module {
            modules
        }
    }
    return serviceLocator
}
