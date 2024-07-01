import XCTest
@testable import ServiceLocator

class ServiceLocatorConcurrencyTests: XCTestCase {
    class TestServiceA {
        static let instanceCount = AtomicInteger(value: 0)
        init() {
            TestServiceA.instanceCount.increment()
        }
    }
    
    class TestServiceB {
        static let instanceCount = AtomicInteger(value: 0)
        
        let testServiceA : TestServiceA
        
        init(testServiceA : TestServiceA) {
            self.testServiceA = testServiceA
            TestServiceB.instanceCount.increment()
        }
    }
    
    class TestModule : ServiceLocatorModule {
        override func build() {
            
            single(TestServiceA.self) {
                TestServiceA()
            }
            
            single(TestServiceB.self) {
                TestServiceB(testServiceA : self.resolve())
            }
        }
    }

    func testThreadSafety() {
        let serviceLocator = startServiceLocator {
            TestModule()
        }
        
        let expectation = self.expectation(description: "ServiceLocator build")
        
        Task {
            await serviceLocator.build()
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10) // Adjust timeout as necessary
        
        
        let iterations = 10000
        let dispatchGroup = DispatchGroup()
        
        for _ in 0..<iterations {
            dispatchGroup.enter()
            DispatchQueue.global().async() {
                var _ : TestServiceB = try! serviceLocator.resolve()
                dispatchGroup.leave()
            }
        }

        // Wait for all the async tasks to complete or timeout after a certain period.
        let waitResult = dispatchGroup.wait(timeout: .now() + 10)
        
        switch waitResult {
            case .success:
            XCTAssertEqual(TestServiceA.instanceCount.getValue(), 1, "Singleton instance count should be exactly one.")
            XCTAssertEqual(TestServiceB.instanceCount.getValue(), 1, "Singleton instance count should be exactly one.")
                
            case .timedOut:
                XCTFail("Test timed out waiting for all operations to complete.")
        }
    }

}
