/// Groups related registrations. Subclass it and register in ``build()``.
///
/// Registered closures typically capture the module to call `resolve()`; that is safe as long as
/// the `ServiceLocator` that built the module stays alive.
open class ServiceLocatorModule {
    public init() {}

    // Set by `ServiceLocator.module(_:)` before `build()` runs.
    weak var locator: ServiceLocator!

    /// Override to register dependencies.
    open func build() {}

    /// Registers a factory that creates a new instance on every resolve.
    public final func factory<T>(_ type: T.Type = T.self, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        locator.factory(type, onMainActor: onMainActor, factory)
    }

    /// Registers a factory under a string identifier. See ``ServiceLocator/factory(_:identifier:onMainActor:_:)``.
    public final func factory<T>(_ type: T.Type = T.self, identifier: String, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        locator.factory(type, identifier: identifier, onMainActor: onMainActor, factory)
    }

    /// Registers a singleton.
    public final func single<T>(_ type: T.Type = T.self, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        locator.single(type, onMainActor: onMainActor, factory)
    }

    /// Registers a singleton under a string identifier. See ``ServiceLocator/single(_:identifier:onMainActor:_:)``.
    public final func single<T>(_ type: T.Type = T.self, identifier: String, onMainActor: Bool = false, _ factory: @escaping () -> T) {
        locator.single(type, identifier: identifier, onMainActor: onMainActor, factory)
    }

    /// Registers a nested module.
    public final func module(_ module: () -> ServiceLocatorModule) {
        locator.module(module)
    }

    /// Resolves a dependency inside a factory. Traps if it cannot be resolved, because a missing
    /// registration is a programmer error; use `ServiceLocator.resolve` to handle the error instead.
    public final func resolve<T>(
        _ type: T.Type = T.self,
        file: StaticString = #filePath,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) -> T {
        locator.resolveOrTrap(type, site: .literal(file: file, fileID: fileID, function: function, line: line))
    }

    /// Resolves the dependency registered under `identifier` inside a factory. Traps if it cannot be resolved.
    public final func resolve<T>(
        _ type: T.Type = T.self,
        identifier: String,
        file: StaticString = #filePath,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) -> T {
        locator.resolveOrTrap(type, identifier: identifier, site: .literal(file: file, fileID: fileID, function: function, line: line))
    }
}
