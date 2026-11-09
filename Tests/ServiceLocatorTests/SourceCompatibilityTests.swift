import Testing
@testable import ServiceLocator

// Mirrors how apps forward their call site as plain strings (the pre-hardening API).
@propertyWrapper
private final class LegacyInject<T>: Dependency<T> {
    var wrappedValue: T { resolvedWrappedValue() }

    override init(_ locator: ServiceLocator, _ file: String = #file, _ fileId: String = #fileID, _ function: String = #function, _ line: Int = #line) {
        super.init(locator, file, fileId, function, line)
    }
}

private func legacyResolve<T>(_ locator: ServiceLocator, _ file: String = #file, _ fileId: String = #fileID, _ function: String = #function, _ line: Int = #line) -> T {
    try! locator.resolve(file, fileId, function, line)
}

@Suite struct SourceCompatibilityTests {
    private final class Box { let value = 42 }

    @Test func positionalStringOverloadsStillResolve() {
        let locator = ServiceLocator()
        locator.single(Box.self) { Box() }

        let viaFunction: Box = legacyResolve(locator)
        #expect(viaFunction.value == 42)

        @LegacyInject(locator) var viaWrapper: Box
        #expect(viaWrapper === viaFunction)
    }
}
