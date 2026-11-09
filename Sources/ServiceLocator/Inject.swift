/// Resolves a dependency from the given locator each time the property is read, so factories
/// yield fresh instances and singletons the shared one.
///
/// ```swift
/// final class Screen {
///     @Inject(locator) var analytics: Analytics
/// }
/// ```
@propertyWrapper
public final class Inject<T>: Dependency<T> {
    public var wrappedValue: T { resolvedWrappedValue() }
}
