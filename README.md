# Service Locator
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
            let appDataSettingsManager: AppDataSettingsManager = self.resolve()

            return AppDataAppLinkFactory(
                    descriptionFactory: appDataSettingsManager,
                    getPluginContainer: PluginController.enabledContainer(for:)
            )
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
