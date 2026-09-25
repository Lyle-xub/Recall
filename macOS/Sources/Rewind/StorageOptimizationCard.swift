import SwiftUI

struct StorageOptimizationCard:View {
    @ObservedObject var optimizer:StorageOptimizer
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Smart storage",systemImage:"arrow.down.right.and.arrow.up.left")
                .font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
            Text("Full-resolution text. Less space.").font(.system(size:16,weight:.medium,design:.rounded))
            Text("Optimize existing images and videos together. Identical screens share one image and a duration. Images use 0.5 compression quality after original-resolution recognition; matching text and coordinates share one index. New video is recorded at up to 720 pixels, 1 fps and a target of 100 kbps, with independent audio tracks. Existing recordings remove embedded audio only when complete independent tracks are verified.")
                .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            if optimizer.running,optimizer.totalItems > 0 {
                ProgressView(value:Double(optimizer.checkedImages+optimizer.checkedVideos+optimizer.checkedIndexes),total:Double(optimizer.totalItems))
                    .tint(.blue).accessibilityLabel("Storage optimization progress")
            }
            HStack(spacing:12) {
                if optimizer.running && !optimizer.waitingForInterface { ProgressView().controlSize(.small) }
                Text(optimizer.waitingForInterface ? "Automatic optimization waits while Recall is open.":optimizer.status).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }
            HStack {
                if optimizer.waitingForInterface { Button("Continue while open") { optimizer.continueWhileOpen() }.buttonStyle(.bordered) }
                if optimizer.running { Button("Pause optimization") { optimizer.cancel() }.buttonStyle(.bordered) }
                else { Button("Optimize images & videos") { optimizer.optimizeExisting() }.buttonStyle(.bordered) }
                Spacer()
            }
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(red:0.975,green:0.985,blue:1),in:RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.blue.opacity(0.07)))
    }
}
