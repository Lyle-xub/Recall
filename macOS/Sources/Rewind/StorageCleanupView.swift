import SwiftUI

struct StorageCleanupView:View {
    @ObservedObject var model:AppModel
    var completed:(String)->Void
    @State private var scope = StorageCleanupScope.trash
    @State private var keepStarred = true
    @State private var plan:StorageCleanupPlan?
    @State private var loading = true
    @State private var clearing = false
    @State private var confirm = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var refreshKey:String { scope.rawValue + "-" + String(keepStarred) }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:14) {
                Image(systemName:"sparkles").font(.system(size:24)).foregroundStyle(.blue)
                    .frame(width:48,height:48).background(.blue.opacity(0.07),in:RoundedRectangle(cornerRadius:16))
                VStack(alignment:.leading,spacing:4) {
                    Text("Clear storage").font(.system(size:23,weight:.semibold,design:.rounded))
                    Text("Choose the memories you no longer need.").font(.system(size:12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment:.leading,spacing:18) {
                HStack { Text("Clear").fontWeight(.medium);Spacer();Picker("Cleanup range",selection:$scope) { ForEach(StorageCleanupScope.allCases) { item in Text(item.title).tag(item) } }.labelsHidden().frame(width:240) }
                Toggle("Keep starred memories",isOn:$keepStarred).toggleStyle(.switch)
            }.disabled(clearing).padding(18).background(Color.blue.opacity(0.035),in:RoundedRectangle(cornerRadius:20))
            VStack(alignment:.leading,spacing:12) {
                HStack(alignment:.firstTextBaseline) {
                    Text(plan.map { StorageUsage.formatted($0.bytes) } ?? "—").font(.system(size:36,weight:.semibold,design:.rounded)).monospacedDigit()
                    Spacer()
                    if loading || clearing { ProgressView().controlSize(.small) }
                }
                Text(clearing ? "Clearing selected memories…":"Estimated space to free").font(.system(size:12)).foregroundStyle(.secondary)
                if let plan,!loading {
                    Divider().opacity(0.5)
                    HStack { Label("\(plan.frameIDs.count) memories",systemImage:"photo.on.rectangle");Spacer();Label("\(plan.sessionIDs.count) recordings",systemImage:"video") }.font(.system(size:12))
                    if plan.skippedActive > 0 || plan.skippedStarred > 0 {
                        Text("Kept: \(plan.skippedActive) memories in unfinished recordings · \(plan.skippedStarred) starred memories")
                            .font(.system(size:11)).foregroundStyle(.secondary)
                    }
                }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color(red:0.965,green:0.98,blue:1),in:RoundedRectangle(cornerRadius:22))
            Text("Screenshots and their search text are cleared. Video, audio and transcripts are removed only when no retained memory uses that recording. Active or unfinished recordings, downloaded models, preferences and app usage history are kept.")
                .font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            if let error { Text(error).font(.system(size:12)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Text("Clearing is permanent.").font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered).disabled(clearing)
                Button("Clear…",role:.destructive) { confirm = true }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(loading || clearing || plan?.frameIDs.isEmpty != false)
            }
        }.padding(26).frame(width:550).background(.white).presentationBackground(.white).preferredColorScheme(.light)
            .font(.system(size:13)).controlSize(.large).interactiveDismissDisabled(clearing)
            .task(id:refreshKey) {
                loading = true; error = nil; plan = nil
                let root = model.store.root, selection = scope, protectStars = keepStarred
                let work = Task.detached(priority:.utility) { try MemoryStore(root:root,readOnly:true).cleanupPlan(scope:selection,keepStarred:protectStars) }
                do {
                    let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                    guard !Task.isCancelled else { return };plan = result;loading = false
                } catch { if !Task.isCancelled { self.error = error.localizedDescription;loading = false } }
            }
            .confirmationDialog("Permanently clear \(plan?.frameIDs.count ?? 0) memories?",isPresented:$confirm,titleVisibility:.visible) {
                Button("Clear permanently",role:.destructive) { clear() }
                Button("Cancel",role:.cancel) {}
            } message: { Text("About \(StorageUsage.formatted(plan?.bytes ?? 0)) of media can be removed. This cannot be undone.") }
    }
    private func clear() {
        guard let plan,!clearing else { return }
        clearing = true;error = nil
        model.cancelAsk();model.back()
        let store = model.store
        Task {
            do {
                let result = try await Task.detached(priority:.utility) { try store.clearStorage(plan) }.value
                model.messages.removeAll { message in message.sources.contains { plan.frameIDs.contains($0.id) } };model.reload()
                let message = "Cleared \(result.memories) memories · \(StorageUsage.formatted(result.bytes)) freed" + (result.pendingFileRemoval ? ". Remaining media will be removed when Recall next opens.":"")
                completed(message);clearing = false;dismiss()
            } catch { self.error = error.localizedDescription;clearing = false }
        }
    }
}
