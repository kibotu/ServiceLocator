# ServiceLocator

A tiny, thread-safe service locator for Swift. No macros, no reflection, no dependencies: register closures, resolve types.

[![Build](https://github.com/kibotu/ServiceLocator/actions/workflows/build-swift.yml/badge.svg)](https://github.com/kibotu/ServiceLocator/actions/workflows/build-swift.yml)
[![Release](https://img.shields.io/github/v/tag/kibotu/ServiceLocator?include_prereleases&sort=semver&label=release)](https://github.com/kibotu/ServiceLocator/releases)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange)](https://www.swift.org/blog/swift-6-released/)
[![Platforms](https://img.shields.io/badge/iOS%2015%20·%20macOS%2012%20·%20tvOS%2015%20·%20watchOS%208%20·%20visionOS%201-lightgrey)](#installation)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE.md)

```swift
final class CheckoutModule: ServiceLocatorModule {
    override func build() {
        single(Analytics.self) { FirebaseAnalytics() }
        single(PaymentService.self) { PaymentService(analytics: self.resolve()) }
        factory(CartViewModel.self) { CartViewModel(payments: self.resolve()) }
    }
}

let locator = startServiceLocator { CheckoutModule() }

final class CartScreen {
    @Inject(locator) var viewModel: CartViewModel
}
```

## Why

- **Small.** A handful of files you can read in one sitting.
- **Safe by default.** Swift 6 language mode, `Sendable`, no data races. Singletons are created exactly once, even under contention.
- **Fast launch.** `build()` creates independent singletons *in parallel*. A singleton that needs another waits for just that one.
- **No hangs.** Circular dependencies and stuck factories throw a `ResolutionError` instead of deadlocking.
- **Main-thread aware.** Services that need UIKit opt in with `onMainActor: true`, without ever deadlocking a waiting main thread.
- **Debuggable.** Every resolve is logged with its requester (`Checkout/CartScreen.swift#viewModel:12`), and crashes point at the offending line.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/kibotu/ServiceLocator", from: "2.0.0"),
],
targets: [
    .target(name: "App", dependencies: ["ServiceLocator"]),
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste `https://github.com/kibotu/ServiceLocator`.

**Requirements:** iOS 15 / macOS 12 / tvOS 15 / watchOS 8 / visionOS 1, Xcode 16, Swift 6.

## Usage

### 1. Register services in modules

A module groups related registrations. Use `single` for one shared instance and `factory` for a new instance on every resolve.

```swift
final class NetworkModule: ServiceLocatorModule {
    override func build() {
        single(ConfigProvider.self) { RemoteConfigProvider() }

        // Dependencies are resolved inside the closure.
        single(URLFactory.self) { URLFactory(config: self.resolve()) }

        factory(AppLinkFactory.self) { AppLinkFactory(settings: self.resolve()) }
    }
}
```

Registrations are keyed by the exact type you pass, so register protocols as `single(Repository.self) { … }` and resolve them as `Repository`. Registering a type twice traps.

### Identifiers

To register several instances of the same type, give each a string identifier. An identified registration is separate from the unidentified one:

```swift
final class NetworkModule: ServiceLocatorModule {
    override func build() {
        factory(HttpClient.self) { HttpClient(requiresLogin: true) }
        factory(identifier: "unauthenticated") { HttpClient(requiresLogin: false) }
    }
}

let client: HttpClient = try locator.resolve(identifier: "unauthenticated")
```

`single(_:identifier:)` works the same way, and inside a module `resolve(identifier:)` doesn't throw. Resolving an unknown identifier throws `.notRegistered`; registering the same type and identifier twice traps.

Compose modules into an app-wide one:

```swift
final class AppModule: ServiceLocatorModule {
    override func build() {
        module { NetworkModule() }
        module { CheckoutModule() }
    }
}
```

Modules are optional; `locator.single(Foo.self) { Foo() }` and `locator.factory(Bar.self) { Bar() }` work directly.

### 2. Start the locator

```swift
let locator = startServiceLocator { AppModule() }
await locator.build() // optional: create singletons now so misconfiguration fails at launch
```

Keep the locator alive for the lifetime of your app. `@Inject` holds it weakly to avoid retain cycles.

### 3. Resolve

With `@Inject`, which resolves on every read. Factories yield a fresh instance each time, singletons the shared one:

```swift
final class ProfileScreen {
    @Inject(locator) var analytics: Analytics
}
```

Or directly. `resolve` throws a `ResolutionError`:

```swift
let analytics: Analytics = try locator.resolve()
```

| Error | Meaning |
|---|---|
| `.notRegistered` | Nothing is registered for that type |
| `.circularDependency` | The type transitively depends on itself |
| `.timedOut` | Another thread or the main thread didn't finish creating it in time |

Inside a module's closures, `resolve()` doesn't throw. A missing registration is a programmer error and traps, pointing at the call site.

## Concurrency

Singletons are created on first resolve, or all at once by `build()`, in any order.

- **Parallel `build()`.** Independent singletons initialize concurrently on background threads. Each is created exactly once.
- **Dependencies wait for dependencies.** A factory that calls `resolve()` on a singleton another thread is still creating waits for exactly that one.
- **Factories must not assume the main thread**, unless registered with `onMainActor: true`.
- **Cycles throw.** Including cycles that span threads.
- **Timeouts.** A resolve that waits longer than `waitTimeout` (default 10 seconds) throws `.timedOut` instead of hanging.

```swift
let locator = startServiceLocator(logger: nil, waitTimeout: 30) { AppModule() } // seconds; nil waits forever
```

### Main-thread services

```swift
single(Router.self, onMainActor: true) {
    MainActor.assumeIsolated { Router() }
}
```

The factory runs on the main thread no matter who resolves it (inline if already there), while everything else still initializes in parallel. If the main thread is itself resolving from the locator, it runs the queued main-thread factories instead of blocking.

> [!WARNING]
> Don't block the main thread any other way (semaphores, `DispatchGroup.wait`) while background threads may resolve `onMainActor` services. The locator can't run their factories, and they will time out.

## Logging

Logging is off by default.

```swift
let locator = startServiceLocator(logger: ServiceLocator.printLogger) { AppModule() }
```

The logger receives registrations, every resolve with its requester, builds and failures. The message is lazy, so check a runtime flag before evaluating it and a disabled logger costs nothing:

```swift
let locator = startServiceLocator(logger: { message in
    if isServiceLocatorLoggingOn { Log.debug(message()) }
}) {
    AppModule()
}
```

## Testing

Prefer a fresh `ServiceLocator()` per test and register fakes directly:

```swift
let locator = ServiceLocator()
locator.single(Analytics.self) { FakeAnalytics() }
```

`reset()` clears all registrations and singletons if you share a locator.

## Custom property wrappers

Bind a wrapper to your own locator to drop the `(locator)` argument:

```swift
@propertyWrapper
final class PluginInject<T>: Dependency<T> {
    var wrappedValue: T { resolvedWrappedValue() }

    init(file: StaticString = #filePath, fileID: StaticString = #fileID,
         function: StaticString = #function, line: UInt = #line) {
        super.init(MyPlugin.shared.locator, file: file, fileID: fileID, function: function, line: line)
    }
}

final class PluginScreen {
    @PluginInject var contactSheet: ContactSheet
}
```

Forwarding `file`, `fileID`, `function` and `line` keeps logs and crash messages pointing at the property declaration rather than your wrapper.

Wrappers that forward their call site as plain `String`s and an `Int` line (the 1.x API) still compile unchanged.

## Migrating from 1.x

- `waitTimeout` takes a `TimeInterval` in seconds (not a `Duration`), so the package supports iOS 15.
- `resolve` and `Dependency.init` gained `StaticString` call-site overloads; the positional `String` forms remain.
- `build()` no longer takes a `file` argument.
- Registering and resolving by `identifier:` is supported (`factory`, `single`, `resolve`).

## Acknowledgements

Inspired by [RouterService](https://github.com/rockbruno/RouterService) and [Swinject](https://github.com/Swinject/Swinject).

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a PR.
