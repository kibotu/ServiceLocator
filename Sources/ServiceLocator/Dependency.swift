/// Base class for property wrappers that resolve `T` from a `ServiceLocator` on every access.
/// Subclass it to bind a wrapper to your own locator; see ``Inject``.
///
/// The locator is held weakly, because singletons that use `@Inject` would otherwise form a
/// retain cycle with it. Keep the locator alive for the lifetime of the app.
open class Dependency<T> {
    private weak var serviceLocator: ServiceLocator?
    private let fileID: StaticString
    private let function: StaticString
    private let line: UInt

    /// The declaration site (file, property name, line) is captured for logs and crash messages.
    public init(
        _ serviceLocator: ServiceLocator,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        self.serviceLocator = serviceLocator
        self.fileID = fileID
        self.function = function
        self.line = line
    }

    /// Resolves `T`. Traps, pointing at the declaration site, if the locator is gone or `T` can't be resolved.
    public final func resolvedWrappedValue() -> T {
        guard let serviceLocator else {
            fatalError(
                "ServiceLocator was deallocated before \(fileID)#\(function) could resolve \(T.self)",
                file: fileID, line: line
            )
        }
        return serviceLocator.resolveOrTrap(T.self, fileID: fileID, function: function, line: line)
    }
}
