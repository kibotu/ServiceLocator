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

// Blocks the main thread (outside the locator), then resolves on it.
@MainActor private func blockMain(for seconds: TimeInterval, thenResolve resolve: () throws -> Bool) rethrows -> Bool {
    Thread.sleep(forTimeInterval: seconds)
    return try resolve()
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

    @Test func buildCreatesSingletonsEagerlyAndOnlyOnce() async throws {
        let created = Locked(0)
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self) {
            created.withValue { $0 += 1 }
            return EnglishGreeter()
        }

        #expect(created.withValue { $0 } == 0)
        await locator.build()
        await locator.build()
        _ = try locator.resolve(EnglishGreeter.self)
        #expect(created.withValue { $0 } == 1)
    }

    @Test func buildIsIndependentOfRegistrationOrder() async throws {
        final class Order: ServiceLocatorModule {
            override func build() {
                single(Consumer.self) { Consumer(greeter: self.resolve()) }
                single(Greeter.self) { EnglishGreeter() }
            }
        }
        let locator = startServiceLocator { Order() }

        await locator.build()

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

    @Test func buildInitializesIndependentSingletonsInParallel() async throws {
        final class Rendezvous: @unchecked Sendable {
            let a = DispatchSemaphore(value: 0), b = DispatchSemaphore(value: 0)
        }
        let rendezvous = Rendezvous()
        let met = Locked(0)
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self) {
            rendezvous.a.signal()
            if rendezvous.b.wait(timeout: .now() + 5) == .success { met.withValue { $0 += 1 } }
            return EnglishGreeter()
        }
        locator.single(Consumer.self) {
            rendezvous.b.signal()
            if rendezvous.a.wait(timeout: .now() + 5) == .success { met.withValue { $0 += 1 } }
            return Consumer(greeter: EnglishGreeter())
        }

        await locator.build()

        #expect(met.withValue { $0 } == 2)
    }

    @Test func dependentWaitsForSlowDependency() async throws {
        let locator = ServiceLocator()
        locator.single(Greeter.self) {
            Thread.sleep(forTimeInterval: 0.2)
            return EnglishGreeter()
        }
        locator.single(Consumer.self) { Consumer(greeter: try! locator.resolve()) }

        await locator.build()

        #expect(try locator.resolve(Consumer.self).greeter as AnyObject === (locator.resolve(Greeter.self) as AnyObject))
    }

    @Test func crossThreadCycleThrowsInsteadOfDeadlocking() async {
        let failures = Locked(0)
        let locator = ServiceLocator()
        locator.single(Greeter.self) {
            do { _ = try locator.resolve(Consumer.self) } catch { failures.withValue { $0 += 1 } }
            return EnglishGreeter()
        }
        locator.single(Consumer.self) {
            do { _ = try locator.resolve(Greeter.self) } catch { failures.withValue { $0 += 1 } }
            return Consumer(greeter: EnglishGreeter())
        }

        await locator.build()

        #expect(failures.withValue { $0 } >= 1)
    }

    @Test func loggerReportsRegistrationResolveAndFailureWithCallSite() throws {
        let lines = Locked<[String]>([])
        let locator = ServiceLocator { message in lines.withValue { $0.append(message()) } }
        locator.single(EnglishGreeter.self) { EnglishGreeter() }

        _ = try locator.resolve(EnglishGreeter.self)
        _ = try? locator.resolve(Consumer.self)

        let log = lines.withValue { $0 }
        #expect(log.contains("register EnglishGreeter"))
        #expect(log.contains { $0.hasPrefix("resolve EnglishGreeter by ServiceLocatorTests/ServiceLocatorTests.swift#loggerReportsRegistrationResolveAndFailureWithCallSite():") })
        #expect(log.contains { $0.hasPrefix("failed to resolve Consumer by ServiceLocatorTests/ServiceLocatorTests.swift#") && $0.contains("No registration for Consumer") })
    }

    @Test func startServiceLocatorAcceptsTrailingModuleAndLogger() throws {
        let logged = Locked(false)
        let locator = startServiceLocator(logger: { _ in logged.withValue { $0 = true } }) {
            ServiceLocatorModule()
        }
        _ = try? locator.resolve(Consumer.self)
        #expect(logged.withValue { $0 })
    }

    @Test func onMainActorSingletonBuildsOnMainWhileOthersStayOffMain() async {
        let onMain = Locked<[String: Bool]>([:])
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self, onMainActor: true) {
            onMain.withValue { $0["main"] = Thread.isMainThread }
            return EnglishGreeter()
        }
        locator.single(Consumer.self) {
            onMain.withValue { $0["background"] = Thread.isMainThread }
            return Consumer(greeter: EnglishGreeter())
        }

        await locator.build()

        #expect(onMain.withValue { $0 } == ["main": true, "background": false])
    }

    @Test @MainActor func onMainActorRunsInlineWhenAlreadyOnMain() throws {
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self, onMainActor: true) { EnglishGreeter() }
        locator.factory(Consumer.self, onMainActor: true) { Consumer(greeter: EnglishGreeter()) }

        _ = try locator.resolve(EnglishGreeter.self)
        _ = try locator.resolve(Consumer.self)
    }

    @Test func onMainActorFactoryResolvedFromBackgroundRunsOnMain() async throws {
        let locator = ServiceLocator()
        let ranOnMain = Locked(false)
        locator.factory(EnglishGreeter.self, onMainActor: true) {
            ranOnMain.withValue { $0 = Thread.isMainThread }
            return EnglishGreeter()
        }

        try await Task.detached { _ = try locator.resolve(EnglishGreeter.self) }.value

        #expect(ranOnMain.withValue { $0 })
    }

    @Test @MainActor func mainThreadWaitingOnBackgroundSingletonDoesNotBlockItsMainActorDependency() async throws {
        let locator = ServiceLocator()
        locator.single(EnglishGreeter.self, onMainActor: true) { EnglishGreeter() }
        locator.single(Consumer.self) {
            Thread.sleep(forTimeInterval: 0.2)
            return Consumer(greeter: try! locator.resolve(EnglishGreeter.self))
        }

        let build = Task.detached { await locator.build() }
        let resolved = try blockMain(for: 0.05) { try locator.resolve(Consumer.self).greeter is EnglishGreeter }
        await build.value

        #expect(resolved)
    }

    @Test @MainActor func mainThreadAlreadyWaitingIsWokenForMainActorWorkQueuedLater() async throws {
        let locator = ServiceLocator()
        locator.factory(Greeter.self, onMainActor: true) { EnglishGreeter() }
        locator.single(Consumer.self) {
            Thread.sleep(forTimeInterval: 0.2)
            return Consumer(greeter: try! locator.resolve())
        }

        let build = Task.detached { await locator.build() }
        let resolved = try blockMain(for: 0.05) { try locator.resolve(Consumer.self).greeter is EnglishGreeter }
        await build.value

        #expect(resolved)
    }

    @Test @MainActor func backgroundThreadsWaitForMainActorSingletonWhileMainIsBusy() async throws {
        let locator = ServiceLocator()
        locator.single(Greeter.self, onMainActor: true) { EnglishGreeter() }

        let first = Task.detached { _ = try locator.resolve(Greeter.self) }
        let second = Task.detached {
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try locator.resolve(Greeter.self)
        }
        let resolved = try blockMain(for: 0.2) { try locator.resolve(Greeter.self) is EnglishGreeter }
        try await first.value
        try await second.value

        #expect(resolved)
    }

    @Test func waitingForSlowSingletonTimesOut() async throws {
        let locator = ServiceLocator(waitTimeout: 0.1)
        locator.single(Greeter.self) {
            Thread.sleep(forTimeInterval: 0.5)
            return EnglishGreeter()
        }

        let creator = Task.detached { _ = try locator.resolve(Greeter.self) }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(throws: ResolutionError.timedOut(type: "Greeter")) {
            try locator.resolve(Greeter.self)
        }
        try await creator.value
    }

    @Test func noTimeoutWaitsForSlowSingleton() async throws {
        let locator = ServiceLocator(waitTimeout: nil)
        locator.single(Greeter.self) {
            Thread.sleep(forTimeInterval: 0.3)
            return EnglishGreeter()
        }

        let creator = Task.detached { _ = try locator.resolve(Greeter.self) }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(try locator.resolve(Greeter.self) is EnglishGreeter)
        try await creator.value
    }

    @Test @MainActor func waitingForBlockedMainThreadTimesOutAndCanRetry() async throws {
        let locator = ServiceLocator(waitTimeout: 0.1)
        let created = Locked(0)
        locator.single(Greeter.self, onMainActor: true) {
            created.withValue { $0 += 1 }
            return EnglishGreeter()
        }

        let background = Task.detached { () -> ResolutionError? in
            do {
                _ = try locator.resolve(Greeter.self)
                return nil
            } catch {
                return error as? ResolutionError
            }
        }
        _ = blockMain(for: 0.3) { true }

        #expect(await background.value == .timedOut(type: "Greeter"))
        #expect(try locator.resolve(Greeter.self) is EnglishGreeter)
        #expect(created.withValue { $0 } == 1)
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

    @Test func modulesCanNestAndResolveEachOther() async throws {
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
        await locator.build()

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
