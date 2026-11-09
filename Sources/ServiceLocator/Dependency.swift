/// Base class for property wrappers that resolve `T` from a `ServiceLocator` on every access.
/// Subclass it to bind a wrapper to your own locator; see ``Inject``.
///
/// The locator is held weakly, because singletons that use `@Inject` would otherwise form a
/// retain cycle with it. Keep the locator alive for the lifetime of the app.
open class Dependency<T> {
    private weak var serviceLocator: ServiceLocator?
    private let site: Site

    /// The declaration site (file, property name, line) is captured for logs and crash messages.
    public init(
        _ serviceLocator: ServiceLocator,
        file: StaticString = #filePath,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        self.serviceLocator = serviceLocator
        self.site = .literal(file: file, fileID: fileID, function: function, line: line)
    }

    /// Source-compatible form of ``init(_:file:fileID:function:line:)`` for wrappers that forward
    /// their own `#file`, `#fileID`, `#function` and `#line` as strings.
    public init(_ serviceLocator: ServiceLocator, _ file: String, _ fileId: String, _ function: String, _ line: Int) {
        self.serviceLocator = serviceLocator
        self.site = .dynamic(file: file, fileID: fileId, function: function, line: UInt(clamping: line))
    }

    /// Resolves `T`. Traps, pointing at the declaration site, if the locator is gone or `T` can't be resolved.
    public final func resolvedWrappedValue() -> T {
        guard let serviceLocator else {
            site.trap("ServiceLocator was deallocated before \(site) could resolve \(T.self)")
        }
        return serviceLocator.resolveOrTrap(T.self, site: site)
    }
}
