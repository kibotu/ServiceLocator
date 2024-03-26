# ServiceLocator for iOS
[![Build](https://github.com/kibotu/ServiceLocator/actions/workflows/build-swift.yml/badge.svg)](https://github.com/kibotu/ServiceLocator/actions/workflows/build-swift.yml) ![GitHub Release](https://img.shields.io/github/v/release/kibotu/ServiceLocator?include_prereleases&sort=semver&display_name=tag) ![Static Badge](https://img.shields.io/badge/Platform%20-%20iOS%20-%20light_green)
[![Static Badge](https://img.shields.io/badge/iOS%20-%20%3E%2016.0%20-%20light_green)](https://support.apple.com/en-us/101566)
[![Static Badge](https://img.shields.io/badge/Swift%205.10%20-%20orange)](https://www.swift.org/blog/swift-5.10-released/)
                
The Service Locator is a design pattern used to decouple the way objects are obtained from the concrete classes that implement them. This is achieved by centralizing object creation to a single location, known as a service locator.

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

            return AppLinkFactory(descriptionFactory: SettingsManage)
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

```swift
lazy var myServiceLocator = startServiceLocator {
    AppModule()
}
```

#### 3. Retrieve dependency

#### 3.1. In data structures

Retrieve dependencies in classes or structs using @Inject. The property wrapper automatically resolves the dependency from the service locator:

```swift
class MyCass {
    @Inject(myServiceLocator) public var contactSheet: ContactSheet
}
```

#### 3.2 Local Variable Injection in Functions

For injecting dependencies within functions or methods, use @Inject before local variable declarations:

```swift
func doSomething() {
    @Inject(myServiceLocator) var contactSheet: ContactSheet
}
```

#### 3.3 Direct Resolution with resolve

If you prefer not using property wrappers, directly resolve dependencies using the service locator's resolve method:

```swift
let configProvider : ConfigProvider = serviceLocator.resolve()
```

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
        super.init(MyPlugin.shared.myServiceLocator)
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

## How to install

### Swift Package Manager

The [Swift Package Manager](https://swift.org/package-manager/) is a tool for managing the distribution of Swift code. It’s integrated with the Swift build system to automate the process of downloading, compiling, and linking dependencies.

To integrate ServiceLocator into your Xcode project using Xcode 15.0 or later, specify it in `File > Swift Packages > Add Package Dependency...`:

```swift
https://github.com/kibotu/ServiceLocator, :branch="<latest-version>"
```

## Requirements

- iOS 16.0 or later
- Xcode 15.0 or later
- Swift 5.10 or later
                            
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
