/// A property wrapper that provides a mechanism for automatic dependency injection.
/// It resolves the dependency of type `T` from the service locator or dependency container.
/// The actual resolution strategy depends on how the underlying services are registered
/// (e.g., as singletons or transient objects).
///
/// Usage:
/// ```
/// @Inject var myService: MyServiceType
/// ```
///
/// Accessing `myService` will automatically resolve `MyServiceType` through the property wrapper.
@propertyWrapper
public final class Inject<T>: Dependency<T> {

    /// The wrapped value of the property wrapper which gets resolved when accessed.
    /// It uses the underlying service locator's resolution mechanism to provide
    /// an instance of type `T`.
    public var wrappedValue: T {
        resolvedWrappedValue()
    }
}

