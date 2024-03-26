import Foundation
import XCTest
@testable import ServiceLocator

class AtomicIntegerTests: XCTestCase {
    
    func testAtomicIntegerThreadSafety() {
        let atomicInt = AtomicInteger(value: 0)
        let expectation = self.expectation(description: "Performing concurrent increments and decrements")
        
        let group = DispatchGroup()
        let iterations = 100000
        
        // Perform increments
        for _ in 0..<iterations {
            DispatchQueue.global().async(group: group) {
                atomicInt.increment()
            }
        }
        
        // Perform decrements
        for _ in 0..<iterations {
            DispatchQueue.global().async(group: group) {
                atomicInt.decrement()
            }
        }

        // Notify when all tasks are completed
        group.notify(queue: .main) {
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5)
        
        // The final value should be zero, as the number of increments and decrements are equal.
        XCTAssertEqual(atomicInt.getValue(), 0, "The final value of AtomicInteger should be zero.")
    }
}


/**
 *
 * Usage:
 * let atomicInt = AtomicInteger(value: 0)
 *
 * Increment the integer atomically
 * atomicInt.increment()
 *
 * Decrement the integer atomically
 * atomicInt.decrement()
 *
 * Get the current value of the integer atomically
 * let currentValue = atomicInt.getValue()
 * print(currentValue)
 *
 * Set a new value atomically
 * atomicInt.setValue(10)
 */
final class AtomicInteger {
    private let queue = DispatchQueue(label: "de.check24.AtomicInteger", attributes: .concurrent)
    private var value: Int
    
    init(value initialValue: Int = 0) {
        value = initialValue
    }
    
    func increment() {
        queue.async(flags: .barrier) {
            self.value += 1
        }
    }
    
    func decrement() {
        queue.async(flags: .barrier) {
            self.value -= 1
        }
    }
    
    func getValue() -> Int {
        queue.sync { value }
    }
    
    func setValue(_ newValue: Int) {
        queue.async(flags: .barrier) {
            self.value = newValue
        }
    }
}
