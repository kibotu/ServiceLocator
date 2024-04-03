import Foundation

/// An open base class representing a dependency that can be resolved from a service locator.
/// It provides the fundamental mechanism to resolve an instance of type `T`.
///
/// Subclasses should utilize `resolvedWrappedValue()` to obtain the resolved instance
/// based on the configuration of the service locator.
open class Dependency<T> {
    /// A weak reference to the service locator, which is used to resolve instances of type `T`.
    internal weak var serviceLocator: ServiceLocator?

    /// Initializes a new dependency with a reference to a service locator.
    ///
    /// - Parameter serviceLocator: The service locator used to resolve instances of type `T`.
    public init(_ serviceLocator: ServiceLocator) {
        self.serviceLocator = serviceLocator
    }

    /// Resolves and returns the wrapped value from the associated service locator.
    ///
    /// - Returns: The resolved instance of type `T`.
    /// - Warning: If 'serviceLocator' is nil, accessing this method will trigger a fatal error.
    public func resolvedWrappedValue() -> T {
        guard let serviceLocatorScope = serviceLocator else {
            fatalError("ServiceLocator is nil. Ensure that it is set before attempting to resolve dependencies.")
        }

        // Attempt to resolve 'T' using the provided 'serviceLocator' and return it.
        // This will either fetch an existing instance or create a new one depending on
        // how 'T' was registered within 'ServiceLocator'.
        return serviceLocatorScope.resolve() as T
    }
}
