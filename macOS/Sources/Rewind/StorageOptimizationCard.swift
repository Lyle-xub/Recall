import SwiftUI

struct StorageOptimizationCard:View {
    @ObservedObject var optimizer:StorageOptimizer
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Smart storage",systemImage:"arrow.down.right.and.arrow.up.left")
                .font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
            Text("Full-resolution text. Less space.").font(.system(size:16,weight:.medium,design:.rounded))
            Text("New memories use one full-resolution recording for both playback and cards. Optimize older images, recordings and the search index here. Recall keeps originals whenever a replacement cannot be verified.")
                .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            if optimizer.running,!optimizer.waitingForInterface,let progress = optimizer.progress {
                ProgressView(value:progress).tint(.blue).accessibilityLabel("Storage optimization progress")
            }
            HStack(spacing:12) {
                if optimizer.running && !optimizer.waitingForInterface { ProgressView().controlSize(.small) }
                Text(optimizer.waitingForInterface ? "Paused while browsing memories.":optimizer.status).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }
            HStack {
                if optimizer.waitingForInterface { Button("Continue while open") { optimizer.continueWhileOpen() }.buttonStyle(.bordered) }
                if optimizer.running { Button("Pause optimization") { optimizer.cancel() }.buttonStyle(.bordered) }
                else { Button("Optimize storage") { optimizer.optimizeExisting() }.buttonStyle(.bordered) }
                Spacer()
            }
        }.disabled(optimizer.maintenanceSuspended).padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(red:0.975,green:0.985,blue:1),in:RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.blue.opacity(0.07)))
    }
}
