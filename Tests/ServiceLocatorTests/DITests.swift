import XCTest
@testable import ServiceLocator

class DITests: XCTestCase {
    
    override func setUp() {
        MyPlugin.serviceLocator = startServiceLocator {
            PluginModule()
        }
    }

    func test_when_adding_non_singleton_to_di_then_resolve_new_object() {
        MyPlugin.serviceLocator.factory(DummyServiceProtocol.self) {
            DummyService()
        }

        let firstResolvedService: DummyServiceProtocol = MyPlugin.serviceLocator.resolve()
        let secondResolvedService: DummyServiceProtocol = MyPlugin.serviceLocator.resolve()

        XCTAssertNotEqual(firstResolvedService.uuid, secondResolvedService.uuid)
    }

    func test_when_adding_singleton_to_di_then_resolve_existing_object() {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }

        let firstResolvedService: DummyServiceProtocol = MyPlugin.serviceLocator.resolve()
        let secondResolvedService: DummyServiceProtocol = MyPlugin.serviceLocator.resolve()

        XCTAssertEqual(firstResolvedService.uuid, secondResolvedService.uuid)
    }

    func test_when_property_is_injected_then_it_must_exist_on_access() {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }

        let sutPropertyWrapper = PropertyWrapperTest()

        XCTAssertNotNil(sutPropertyWrapper.dummyService)
    }

    func test_when_propery_wrapper_in_depedency_graph_then_all_depedencies_can_be_resolved() {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }

        MyPlugin.serviceLocator.factory(PropertyWrapperTest.self) {
            PropertyWrapperTest()
        }

        let firstResolvedService: DummyServiceProtocol = MyPlugin.serviceLocator.resolve()
        let propertyWrapper: PropertyWrapperTest = MyPlugin.serviceLocator.resolve()

        XCTAssertNotNil(firstResolvedService)
        XCTAssertNotNil(propertyWrapper)
    }

    func test_when_use_resolve_in_factory_then_obejcts_are_created() {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }

        MyPlugin.serviceLocator.single(DummyServiceProtocol2.self) {
            let service = DummyService2()
            service.dummyService = MyPlugin.serviceLocator.resolve()
            return service
        }

        let firstResolvedService: DummyServiceProtocol = MyPlugin.serviceLocator.resolve()
        let secondResolvedService: DummyServiceProtocol2 = MyPlugin.serviceLocator.resolve()

        XCTAssertNotNil(firstResolvedService)
        XCTAssertNotNil(secondResolvedService)
    }
}


protocol DummyServiceProtocol {
    var uuid: String { get set }
}

class DummyService: DummyServiceProtocol {
    var uuid: String = UUID().uuidString
}

protocol DummyServiceProtocol2 {
    var uuid: String { get set }
}

class DummyService2: DummyServiceProtocol2 {
    var uuid: String = UUID().uuidString

    var dummyService: DummyService?
}

class PropertyWrapperTest {
    @MyPluginInject var dummyService: DummyServiceProtocol
}

@propertyWrapper
internal final class MyPluginInject<T>: Dependency<T> {
    public var wrappedValue: T {
        resolvedWrappedValue()
    }

    public init() {
        super.init(MyPlugin.serviceLocator)
    }
}

internal class MyPlugin {
    
    // swiftlint:disable implicitly_unwrapped_optional
    internal static var serviceLocator: ServiceLocator!
    // swiftlint:enable implicitly_unwrapped_optional
}

internal class PluginModule : ServiceLocatorModule {
    override func build() {
        
    }
}
