import XCTest
@testable import ServiceLocator

class DITests: XCTestCase {
    
    override func setUp() {
       super.setUp()
       MyPlugin.serviceLocator = startServiceLocator {
           PluginModule()
       }
       
       let expectation = self.expectation(description: "ServiceLocator build")
       
       Task {
           await MyPlugin.serviceLocator.build()
           expectation.fulfill()
       }
       
       waitForExpectations(timeout: 10) // Adjust timeout as necessary
    }
    
    override class func tearDown() {
        MyPlugin.serviceLocator.reset()
    }

    func test_when_adding_non_singleton_to_di_then_resolve_new_object() {
        MyPlugin.serviceLocator.factory(DummyServiceProtocol.self) {
            DummyService()
        }

        let firstResolvedService: DummyServiceProtocol = try! MyPlugin.serviceLocator.resolve()
        let secondResolvedService: DummyServiceProtocol = try! MyPlugin.serviceLocator.resolve()

        XCTAssertNotEqual(firstResolvedService.uuid, secondResolvedService.uuid)
    }

    func test_when_adding_singleton_to_di_then_resolve_existing_object() async {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }
        
        await MyPlugin.serviceLocator.build()

        let firstResolvedService: DummyServiceProtocol = try! MyPlugin.serviceLocator.resolve()
        let secondResolvedService: DummyServiceProtocol = try! MyPlugin.serviceLocator.resolve()

        XCTAssertEqual(firstResolvedService.uuid, secondResolvedService.uuid)
    }

    func test_when_property_is_injected_then_it_must_exist_on_access() async {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }
        
        await MyPlugin.serviceLocator.build()

        let sutPropertyWrapper = PropertyWrapperTest()

        XCTAssertNotNil(sutPropertyWrapper.dummyService)
    }

    func test_when_propery_wrapper_in_depedency_graph_then_all_depedencies_can_be_resolved() async {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }

        MyPlugin.serviceLocator.factory(PropertyWrapperTest.self) {
            PropertyWrapperTest()
        }
        
        await MyPlugin.serviceLocator.build()

        let firstResolvedService: DummyServiceProtocol = try! MyPlugin.serviceLocator.resolve()
        let propertyWrapper: PropertyWrapperTest = try! MyPlugin.serviceLocator.resolve()

        XCTAssertNotNil(firstResolvedService)
        XCTAssertNotNil(propertyWrapper)
    }

    func test_when_use_resolve_in_factory_then_obejcts_are_created() async {
        MyPlugin.serviceLocator.single(DummyServiceProtocol.self) {
            DummyService()
        }

        MyPlugin.serviceLocator.single(DummyServiceProtocol2.self) {
            let service = DummyService2()
            service.dummyService = try! MyPlugin.serviceLocator.resolve()
            return service
        }
        
        await MyPlugin.serviceLocator.build()

        let firstResolvedService: DummyServiceProtocol = try! MyPlugin.serviceLocator.resolve()
        let secondResolvedService: DummyServiceProtocol2 = try! MyPlugin.serviceLocator.resolve()

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
