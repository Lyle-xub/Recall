import Foundation

/// One operation in flight and one replaceable pending request. Rapid pointer
/// input never builds a queue of obsolete disk reads. Results apply only if the
/// request is still current; cancellation cannot revive an old view.
@MainActor final class LatestRequestWorker<Input:Sendable,Output:Sendable> {
    private let operation: @Sendable (Input) throws -> Output
    private var pending: (input:Input,revision:Int,apply:(Output)->Void,fail:(Error)->Void)?
    private var task: Task<Void,Never>?
    private var revision = 0
    private(set) var operationCount = 0
    init(operation:@escaping @Sendable (Input)throws->Output) { self.operation = operation }
    func submit(_ input:Input,apply:@escaping(Output)->Void,fail:@escaping(Error)->Void = {_ in}) {
        revision += 1; pending = (input,revision,apply,fail)
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while let request = pending {
                pending = nil; operationCount += 1
                let input = request.input, operation = operation
                let result = await Task.detached(priority:.userInitiated) { Result { try operation(input) } }.value
                if revision == request.revision {
                    switch result { case .success(let value):request.apply(value); case .failure(let error):request.fail(error) }
                }
            }
            task = nil
        }
    }
    func cancel() { revision += 1; pending = nil }
    func waitUntilIdle() async { await task?.value }
}
