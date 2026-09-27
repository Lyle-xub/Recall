import Foundation

struct ArchiveFooterRequest:Sendable {
    let id:String
    let key:String
    let frame:MemoryFrame
    let night:Bool
    let aspect:CGFloat
    let row:Double
}

/// One bounded queue and at most two preparations. Mutating a material already
/// attached to SceneKit is exclusively the caller's MainActor responsibility.
@MainActor final class ArchiveFooterLoader {
    typealias Prepare=@Sendable (ArchiveFooterRequest) async -> ArchivePreparedFooter?
    private struct Job {
        let request:ArchiveFooterRequest
        let version:UInt64
        let apply:(ArchivePreparedFooter)->Void
    }
    private let prepare:Prepare
    private var wanted:[String:(String,UInt64)]=[:]
    private var pending:[String:Job]=[:]
    private var worker:Task<Void,Never>?
    private var revision:UInt64=0
    private var active=true
    private var selected:String?
    private var center:Double=0
    private(set) var maximumConcurrency=0
    private(set) var inFlightCount=0
    var pendingCount:Int {pending.count}
    init(prepare:Prepare? = nil) {
        self.prepare=prepare ?? {request in ArchiveInformationRenderer.prepare(request)}
    }
    deinit {worker?.cancel()}
    func contains(id:String,key:String)->Bool {wanted[id]?.0 == key}
    func request(_ request:ArchiveFooterRequest,apply:@escaping(ArchivePreparedFooter)->Void) {
        guard active,!contains(id:request.id,key:request.key),pending.count < 262 || pending[request.id] != nil else {return}
        revision &+= 1;wanted[request.id]=(request.key,revision)
        pending[request.id]=Job(request:request,version:revision,apply:apply)
        start()
    }
    func retain(_ ids:Set<String>) {
        wanted=wanted.filter {ids.contains($0.key)};pending=pending.filter {ids.contains($0.key)}
    }
    func prioritize(selected:String?,center:Double) {self.selected=selected;self.center=center}
    func stop() {active=false;worker?.cancel();pending.removeAll();wanted.removeAll()}
    func resume() {active=true;start()}
    func waitUntilIdle() async {while let worker {await worker.value}}
    private func start() {
        guard active,worker == nil,!pending.isEmpty else {return}
        worker=Task { [weak self] in await self?.run() }
    }
    private func run() async {
        while active,!Task.isCancelled,!pending.isEmpty {
            let jobs=Array(pending.values.sorted {a,b in
                if (a.request.id == selected) != (b.request.id == selected) {return a.request.id == selected}
                let ad=abs(a.request.row-center),bd=abs(b.request.row-center)
                return ad == bd ? a.request.id < b.request.id:ad < bd
            }.prefix(2))
            for job in jobs {pending[job.request.id]=nil}
            inFlightCount=jobs.count;maximumConcurrency=max(maximumConcurrency,inFlightCount)
            let prepare=self.prepare,requests=jobs.map(\.request)
            let values=await Task.detached(priority:.utility) {
                await withTaskGroup(of:(Int,ArchivePreparedFooter?).self) {group in
                    for (index,request) in requests.enumerated() {group.addTask {(index,await prepare(request))}}
                    var values:[(Int,ArchivePreparedFooter?)]=[]
                    for await value in group {values.append(value)}
                    return values
                }
            }.value
            inFlightCount=0
            for (index,value) in values {
                let job=jobs[index]
                guard active,!Task.isCancelled,wanted[job.request.id]?.1 == job.version,let value else {continue}
                job.apply(value)
            }
        }
        worker=nil
        if active,!pending.isEmpty {start()}
    }
}
