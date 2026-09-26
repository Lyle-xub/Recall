import SwiftUI

struct StorageUsageChart: View {
    let usage: StorageUsage
    private func color(_ kind:StorageCategory.Kind)->Color {
        switch kind {
        case .screenshots: Color(red:0.43,green:0.71,blue:0.94)
        case .video: Color(red:0.61,green:0.65,blue:0.88)
        case .audio: Color(red:0.92,green:0.68,blue:0.69)
        case .models: Color(red:0.43,green:0.77,blue:0.71)
        case .index: Color(red:0.94,green:0.77,blue:0.49)
        case .other: Color(red:0.73,green:0.79,blue:0.84)
        }
    }
    private var slices: [(StorageCategory,Double,Double)] {
        var start = 0.0
        return usage.categories.map { item in
            let end = start + (usage.totalBytes == 0 ? 0:Double(item.bytes)/Double(usage.totalBytes))
            defer { start = end }; return (item,start,end)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:30) {
                ZStack {
                    Circle().stroke(.blue.opacity(0.04),lineWidth:14)
                    ForEach(slices,id:\.0.id) { item,start,end in
                        if end > start { Circle().trim(from:start,to:end).stroke(color(item.kind),style:StrokeStyle(lineWidth:14,lineCap:.butt)).rotationEffect(.degrees(-90)) }
                    }
                    VStack(spacing:4) {
                        Text(StorageUsage.formatted(usage.totalBytes)).font(.system(size:24,weight:.semibold,design:.rounded)).minimumScaleFactor(0.6).lineLimit(1)
                        Text("total used").font(.system(size:10)).foregroundStyle(.secondary)
                    }.padding(18)
                }.frame(width:154,height:154).padding(10).accessibilityElement(children:.ignore).accessibilityLabel("Recall storage: \(StorageUsage.formatted(usage.totalBytes))")
                VStack(spacing:12) {
                    ForEach(usage.categories) { item in
                        HStack(spacing:8) {
                            Circle().fill(color(item.kind)).frame(width:7,height:7)
                            Text(item.kind.label).font(.system(size:12))
                            Spacer(minLength:8)
                            Text(StorageUsage.formatted(item.bytes)).font(.system(size:11,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(.secondary)
                        }.accessibilityElement(children:.combine)
                    }
                }
            }
            if let free = usage.availableBytes,let capacity = usage.capacityBytes,capacity > 0 {
                Divider().opacity(0.5)
                HStack { Text("Disk available"); Spacer(); Text("\(StorageUsage.formatted(free)) of \(StorageUsage.formatted(capacity))").monospacedDigit() }.font(.system(size:11)).foregroundStyle(.secondary)
                GeometryReader { geo in
                    Capsule().fill(.blue.opacity(0.05))
                        .overlay(alignment:.leading) { Capsule().fill(Color(red:0.64,green:0.76,blue:0.86)).frame(width:geo.size.width * min(1,max(0,Double(capacity-free)/Double(capacity)))) }
                }.frame(height:5).accessibilityLabel("Disk used: \(Int(Double(capacity-free)/Double(capacity)*100)) percent")
            }
            Text("Size on disk includes memories in Trash and downloaded models. Updated \(usage.measuredAt.recallFormatted(date:.omitted,time:.shortened)).")
                .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if usage.unreadableFiles > 0 { Text("Some files could not be measured; this total may be incomplete.").font(.system(size:11)).foregroundStyle(.orange) }
        }
    }
}
