import Foundation
import Combine

let lock = NSRecursiveLock()
let statusStream: PassthroughSubject<Int, Never> = .init()

func asynchronousFunction(_ value: Int) -> AnyPublisher<Int, Never> {
    Deferred<Just<Int>> {
        Just(value)
    }
    .flatMap { _ in statusStream }
    .filter({ $0 == value })
    .first()
    .synchronized(using: lock)    // <-- This works
    .print("asynchronousFunction(\(value))")
    .eraseToAnyPublisher()
}

let stream4 = asynchronousFunction(4)
    .sink { value in }

let stream1 = asynchronousFunction(1)
    .sink { value in }

for _ in 0...1 {
    for value in 0...5 {
        // Send value to stream from main thread
        statusStream.send(value)
        Thread.sleep(forTimeInterval: 2)
    }
}

// These are the logs without using any sync mechanism. The issue is that value 1 is read before value 4, which was called first.
//
// asynchronousFunction(1): receive value: (1)
// asynchronousFunction(1): receive finished
// asynchronousFunction(4): receive value: (4)
// asynchronousFunction(4): receive finished
//
// These are the logs we try to achieve (no matter the subscription phase):
//
// asynchronousFunction(4): receive value: (4)
// asynchronousFunction(1): receive finished
// asynchronousFunction(1): receive value: (1)
// asynchronousFunction(4): receive finished

// My solution
extension Publisher {
    /// Method that can be used to synchronize mupltile publishers. Subscription and execution is performed on new global thread, so do not rely on result being
    /// called on calling thread.
    ///
    /// - Parameters:
    ///   - lock: Shared lock across all publisher calls.
    ///
    /// - Returns: New publisher that is synchronized across multiple parallel executions.
    func synchronized(using lock: NSRecursiveLock) -> AnyPublisher<Output, Failure> {
        Deferred {
            Future { promise in
                // Signal to shared lock that we are about to start
                lock.lock()

                // Use local semaphore to block current thread and wait for asynchronous execution (in order not to loose subscription)
                let semaphore = DispatchSemaphore(value: 0)

                // Do the work
                var result: Result<Output, Failure>!
                let sub = self
                    .mapToResult()
                    .handleEvents(
                        receiveOutput: { result = $0 },
                        receiveCompletion: { _ in
                            semaphore.signal()
                        },
                        receiveCancel: {
                            semaphore.signal()
                        }
                    )
                    .sink(receiveValue: { _ in })

                // Release all resources
                semaphore.wait()
                lock.unlock()

                // Return the execution result
                promise(result)
            }
        }
        .subscribe(on: DispatchQueue.global())  // Subscribe on new thread so we don't block anything else
        .eraseToAnyPublisher()
    }

    func mapToResult() -> AnyPublisher<Result<Output, Failure>, Never> {
        self.map { Result<Output, Failure>.success($0) }
            .catch { Just<Result<Output, Failure>>(.failure($0)) }
            .eraseToAnyPublisher()
    }
}
