import Foundation

/// Why a dependency could not be resolved.
public enum ResolutionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Nothing is registered for the requested type.
    case notRegistered(type: String)
    /// The type (transitively) depends on itself.
    case circularDependency(type: String)

    public var description: String {
        switch self {
        case .notRegistered(let type): "No registration for \(type)"
        case .circularDependency(let type): "Circular dependency while resolving \(type)"
        }
    }

    public var errorDescription: String? { description }
}
