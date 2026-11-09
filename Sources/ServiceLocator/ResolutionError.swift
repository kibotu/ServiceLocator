import Foundation

/// Why a dependency could not be resolved.
public enum ResolutionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Nothing is registered for the requested type.
    case notRegistered(type: String)
    /// The type (transitively) depends on itself.
    case circularDependency(type: String)
    /// Waiting for another thread, or the main thread, to create the type exceeded the locator's `waitTimeout`.
    case timedOut(type: String)

    public var description: String {
        switch self {
        case .notRegistered(let type):
            "No registration for \(type). Registrations match the exact type: register it with single(\(type).self) { ... } or factory(\(type).self) { ... }, and resolve it as that type, not as a protocol it conforms to."
        case .circularDependency(let type): "Circular dependency while resolving \(type): its factory (transitively) resolves \(type) again"
        case .timedOut(let type):
            "Timed out waiting for \(type) to be created on another thread. Its factory may be blocked, or, for onMainActor registrations, the main thread is blocked outside the locator. If the factory is just slow, raise or disable waitTimeout."
        }
    }

    public var errorDescription: String? { description }
}
