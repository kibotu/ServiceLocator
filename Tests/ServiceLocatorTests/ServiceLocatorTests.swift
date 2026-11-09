import Foundation
import Testing
@testable import ServiceLocator

private protocol Greeter {}
private final class EnglishGreeter: Greeter {}
private final class Consumer {
    let greeter: any Greeter
    init(greeter: any Greeter) { self.greeter = greeter }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

struct ServiceLocatorTests {
    @Test func factoryCreatesNewInstanceEachTime() throws {
        let locator = ServiceLocator()
        locator.factory(EnglishGreeter.self) { EnglishGreeter() }

        #expect(try locator.resolve(EnglishGreeter.self) !== locator.resolve(EnglishGreeter.self))
    }

    @Test func singletonIsShared() throws {
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self) { EnglishGreeter() }

        #expect(try locator.resolve(EnglishGreeter.self) === locator.resolve(EnglishGreeter.self))
    }

    @Test func resolvesByRegisteredProtocol() throws {
        let locator = ServiceLocator()
        locator.single(Greeter.self) { EnglishGreeter() }

        let greeter: any Greeter = try locator.resolve()
        #expect(greeter is EnglishGreeter)
    }

    @Test func unregisteredTypeThrows() {
        #expect(throws: ResolutionError.notRegistered(type: "EnglishGreeter")) {
            try ServiceLocator().resolve(EnglishGreeter.self)
        }
    }

    @Test func buildCreatesSingletonsEagerlyAndOnlyOnce() throws {
        let created = Locked(0)
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self) {
            created.withValue { $0 += 1 }
            return EnglishGreeter()
        }

        #expect(created.withValue { $0 } == 0)
        locator.build()
        locator.build()
        _ = try locator.resolve(EnglishGreeter.self)
        #expect(created.withValue { $0 } == 1)
    }

    @Test func buildIsIndependentOfRegistrationOrder() throws {
        final class Order: ServiceLocatorModule {
            override func build() {
                single(Consumer.self) { Consumer(greeter: self.resolve()) }
                single(Greeter.self) { EnglishGreeter() }
            }
        }
        let locator = startServiceLocator { Order() }

        locator.build()

        #expect(try locator.resolve(Consumer.self).greeter is EnglishGreeter)
    }

    @Test func circularDependencyThrows() {
        let locator = ServiceLocator()
        let failure = Locked<(any Error)?>(nil)
        locator.factory(Greeter.self) {
            do { _ = try locator.resolve(Greeter.self) } catch { failure.withValue { $0 = error } }
            return EnglishGreeter()
        }

        _ = try? locator.resolve(Greeter.self)

        #expect(failure.withValue { $0 } as? ResolutionError == .circularDependency(type: "Greeter"))
    }

    @Test func resetClearsRegistrationsAndInstances() throws {
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self) { EnglishGreeter() }
        let before = try locator.resolve(EnglishGreeter.self)

        locator.reset()
        #expect(throws: ResolutionError.self) { try locator.resolve(EnglishGreeter.self) }

        locator.single(EnglishGreeter.self) { EnglishGreeter() }
        #expect(try locator.resolve(EnglishGreeter.self) !== before)
    }

    @Test func modulesCanNestAndResolveEachOther() throws {
        final class Inner: ServiceLocatorModule {
            override func build() { single(Greeter.self) { EnglishGreeter() } }
        }
        final class Outer: ServiceLocatorModule {
            override func build() {
                module { Inner() }
                single(Consumer.self) { Consumer(greeter: self.resolve()) }
            }
        }

        let locator = startServiceLocator { Outer() }
        locator.build()

        #expect(try locator.resolve(Consumer.self).greeter is EnglishGreeter)
    }

    @Test func injectResolvesOnAccess() {
        final class Screen {
            @Inject var greeter: any Greeter
            init(_ locator: ServiceLocator) { _greeter = Inject(locator) }
        }
        let locator = ServiceLocator()
        locator.single(Greeter.self) { EnglishGreeter() }

        #expect(Screen(locator).greeter is EnglishGreeter)
    }

    @Test func concurrentResolveCreatesSingletonsOnce() throws {
        let created = Locked(0)
        let locator = ServiceLocator()
        locator.single(Greeter.self) {
            created.withValue { $0 += 1 }
            return EnglishGreeter()
        }
        locator.single(Consumer.self) {
            created.withValue { $0 += 1 }
            return Consumer(greeter: try! locator.resolve())
        }

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            _ = try! locator.resolve(Consumer.self)
        }

        #expect(created.withValue { $0 } == 2)
    }
}
