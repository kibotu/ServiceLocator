/// Base class for property wrappers that resolve `T` from a `ServiceLocator` on every access.
/// Subclass it to bind a wrapper to your own locator; see ``Inject``.
///
/// The locator is held weakly, because singletons that use `@Inject` would otherwise form a
/// retain cycle with it. Keep the locator alive for the lifetime of the app.
open class Dependency<T> {
    private weak var serviceLocator: ServiceLocator?
    private let file: StaticString
    private let line: UInt

    public init(_ serviceLocator: ServiceLocator, file: StaticString = #fileID, line: UInt = #line) {
        self.serviceLocator = serviceLocator
        self.file = file
        self.line = line
    }

    /// Resolves `T`. Traps, pointing at the declaration site, if the locator is gone or `T` can't be resolved.
    public final func resolvedWrappedValue() -> T {
        guard let serviceLocator else {
            fatalError("ServiceLocator was deallocated before resolving \(T.self)", file: file, line: line)
        }
        do {
            return try serviceLocator.resolve(T.self, file: file, line: line)
        } catch {
            fatalError("Failed to resolve \(T.self): \(error)", file: file, line: line)
        }
    }
}
