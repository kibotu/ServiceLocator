# ServiceLocator for iOS
[![Build](https://github.com/kibotu/ServiceLocator/actions/workflows/build-swift.yml/badge.svg)](https://github.com/kibotu/ServiceLocator/actions/workflows/build-swift.yml) [![GitHub Tag](https://img.shields.io/github/v/tag/kibotu/ServiceLocator?include_prereleases&sort=semver)](https://github.com/kibotu/ServiceLocator/releases) ![Static Badge](https://img.shields.io/badge/Platform%20-%20iOS%20-%20light_green)
[![Static Badge](https://img.shields.io/badge/iOS%20-%20%3E%2016.0%20-%20light_green)](https://support.apple.com/en-us/101566)
[![Static Badge](https://img.shields.io/badge/Swift%206%20-%20orange)](https://www.swift.org/blog/swift-6-released/)

The Service Locator is a design pattern used to decouple the way objects are obtained from the concrete classes that implement them. This is achieved by centralizing object creation to a single location, known as a service locator.

This tiny project has been inspired by [RouterService](https://github.com/rockbruno/RouterService) and [Swinject](https://github.com/Swinject/Swinject)

## Getting Started

### 1. Define Modules for Dependency Registration

Modules group related service registrations. They override the build() method to define how services should be registered with the locator.

```swift
class MyModule: ServiceLocatorModule {

    override func build() {

        // singletons
        single(ConfigProviderProtocol.self) {
            ConfigProvider()
        }

        // get dependencies with resolve
        single(URLFactory.self) {
            URLFactory(remoteConfigProvider: self.resolve())
        }

        // factory
        factory(AppLinkFactory.self) {
            let settingsManager: SettingsManager = self.resolve()

            return AppLinkFactory(descriptionFactory: settingsManager)
        }
    }
}
```

Tip: Define an application-wide module that includes other modules.


```swift
class AppModule: ServiceLocatorModule {

    override func build() {
        module { MyModule() }
    }
}
```

#### 2. Initialize the Service Locator

Keep the locator alive for the lifetime of your app; `@Inject` holds it weakly.

```swift
let locator = startServiceLocator {
    AppModule()
}
await locator.build() // optional: creates singletons now, so misconfiguration fails at launch
```

Singletons are created on first resolve, or by `build()`, in any order. `build()` initializes them **in parallel** on background threads: a singleton whose factory calls `resolve()` waits only for the singletons it needs, and each is created exactly once. Factories therefore must not assume the main thread, unless registered with `onMainActor: true`. Circular dependencies throw instead of deadlocking. A resolve that waits longer than `waitTimeout` (default 10 seconds) for another thread throws `ResolutionError.timedOut` instead of hanging; pass `waitTimeout: nil` to wait forever, e.g. `startServiceLocator(logger: nil, waitTimeout: 30) { AppModule() }`. Registering a type twice traps.

#### 3. Retrieve dependencies

With `@Inject`, which resolves on every read (factories give a fresh instance each time):

```swift
class MyClass {
    @Inject(locator) var contactSheet: ContactSheet
}

func doSomething() {
    @Inject(locator) var contactSheet: ContactSheet
}
```

Or directly. `resolve` throws a `ResolutionError` (`.notRegistered`, `.circularDependency`, `.timedOut`):

```swift
let configProvider: ConfigProvider = try locator.resolve()
```

Inside a module's factory closures, `resolve()` doesn't throw; it traps if the dependency is missing.

Services that need the main thread (UIKit, main-actor state) opt in per registration:

```swift
single(Router.self, onMainActor: true) {
    MainActor.assumeIsolated { Router() }
}
```

The factory then runs on the main thread no matter who resolves or builds (inline if already on main), while everything else still initializes in parallel. This needs the main thread to be either free or itself resolving from the locator, which then runs the queued main-thread factories instead of blocking. Don't block the main thread any other way (semaphores, `DispatchGroup.wait`) while background threads may resolve `onMainActor` services.

Registrations also work without modules: `locator.single(Foo.self) { Foo() }`, `locator.factory(Bar.self) { Bar() }`.

#### 4. Testing

`reset()` clears all registrations and singletons. Prefer a fresh `ServiceLocator()` per test.

#### Tips and Customizations

##### Custom Property Wrapper

Create a tailored property wrapper if you have specific needs or want to simplify usage for a particular scope, like plugins in this example:

```swift
@propertyWrapper
internal final class PluginInject<T>: Dependency<T> {

    public var wrappedValue: T {
        resolvedWrappedValue()
    }

    public init() {
        super.init(MyPlugin.shared.locator)
    }
}
```

Usage:

```swift
class MyClass {
    @PluginInject var contactSheet: ContactSheet
}
```

```swift
func doSomething() {
    @PluginInject var contactSheet: ContactSheet
}
```

### Enabling Logging

```swift
let locator = startServiceLocator(logger: ServiceLocator.printLogger) { AppModule() }
```

The logger receives registrations, every resolve with its requester (`Module/File.swift#property:line`), builds and failures. Plug in your own logging, and check a runtime flag before evaluating the lazy message:

```swift
let locator = startServiceLocator(logger: { message in
    if isServiceLocatorLoggingOn { Log.debug(message()) }
}) {
    AppModule()
}
```

## How to install

### Swift Package Manager

Add the dependency to your `Package.swift`

```swift
    products: [
      ...
    ]
    dependencies: [
        .package(url: "https://github.com/kibotu/ServiceLocator", from: "2.0.0"),
    ],
    targets: [
      ...
    ]
```

## Requirements

- iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, visionOS 1.0 or later
- Xcode 16.0 or later
- Swift 6.0 or later (Swift 6 language mode clean; `ServiceLocator` is `Sendable` and thread-safe)
                            
Contributions welcome!

### License
<pre>
Copyright 2024 Jan Rabe & CHECK24

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
</pre>


