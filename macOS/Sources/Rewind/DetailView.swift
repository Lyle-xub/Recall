import SwiftUI
import AVKit

struct DetailView: View {
    @ObservedObject var model: AppModel
    let frame: MemoryFrame
    @State private var selectedLine = ""
    @State private var showOriginalTracks = false
    private var visibleLines: [TranscriptLine] { showOriginalTracks ? model.originalTranscriptLines : model.lines }
    private var twoSides: Bool { TranscriptPresentation.usesTwoSides(visibleLines) }
    private var showSource: Bool { Set(visibleLines.map(\.speaker)).count > 1 }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var regions: [TextRegion] {model.meetingView && frame.meetingImagePath != nil ? frame.meetingRegions:frame.regions}
    var body: some View {
        HStack(alignment:.top,spacing:25) {
            VStack(spacing:11) {
                ZStack(alignment:.bottomLeading) {
                    if let player = model.player { RecordingPlayerView(player:player) }
                    else {
                        SelectableMemoryImage(url:model.store.root.appendingPathComponent(model.meetingView ? frame.meetingImagePath ?? frame.imagePath:frame.imagePath),regions:regions)
                    }

                    if let meeting = frame.meetingImagePath {
                        Button {model.meetingView.toggle();model.player?.pause();model.player = nil} label: {
                            MeetingThumbnail(url:model.store.root.appendingPathComponent(model.meetingView ? frame.imagePath:meeting))
                        }.buttonStyle(ComfortableButtonStyle()).padding(12).help("Switch between meeting and desktop")
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                HStack(spacing:14) {
                    AppBadge(name:frame.appName,size:20); Text(frame.title).lineLimit(1).font(.system(size:12,weight:.medium));Spacer()
                    Button {model.showText.toggle()} label: {Image(systemName:"text.viewfinder")}.help("Show selectable text").popover(isPresented:$model.showText) {ScrollView(showsIndicators:false) {Text(frame.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(20)}.scrollIndicators(.never).frame(width:530,height:400)}
                    Button {model.copy(frame.text)} label: {Image(systemName:"doc.on.doc")}.help("Copy all recognized text")
                    Button {model.star(frame)} label: {Image(systemName:frame.starred ? "star.fill":"star")}.help("Star this memory")
                    if frame.sessionID != nil && !frame.demo {Button {model.openVideo()} label: {Image(systemName:"play.fill")}.help("Play recording")}
                    RecognitionStatusView(model:model,frame:frame)
                    if frame.deletedAt == nil {Button {model.delete(frame)} label: {Image(systemName:"trash")}.help("Move to Trash")} else {Button("Restore") {model.restore(frame)}}
                }.buttonStyle(ComfortableButtonStyle()).padding(.horizontal,5)
            }
            if !model.lines.isEmpty {
                VStack(spacing:12) {
                    HStack {
                        Text("Transcript").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if model.originalTranscriptLines.count != model.lines.count {
                            Button { showOriginalTracks.toggle() } label: {
                                Image(systemName:showOriginalTracks ? "line.3.horizontal.decrease.circle.fill":"line.3.horizontal.decrease.circle")
                                    .frame(width:32,height:32).contentShape(Circle())
                            }.buttonStyle(.plain).foregroundStyle(Color.overlayControl)
                                .accessibilityLabel(showOriginalTracks ? "Hide microphone echoes":"Show original audio tracks")
                                .help(showOriginalTracks ? "Hide repeated microphone echoes":"Show original audio tracks, including echoes")
                        }
                        Button { model.copy(visibleLines.map(\.text).joined(separator:"\n\n")) } label: {
                            Image(systemName:"doc.on.doc").frame(width:32,height:32).contentShape(Circle())
                        }.buttonStyle(.plain).foregroundStyle(Color.overlayControl).help("Copy transcript").accessibilityLabel("Copy transcript")
                    }.padding(.horizontal,6)
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators:false) {
                            LazyVStack(alignment:.leading,spacing:12) {
                                ForEach(visibleLines) { line in
                                    let trailing = twoSides && line.speaker != visibleLines.first?.speaker
                                    HStack(alignment:.top,spacing:0) {
                                        if trailing { Spacer(minLength:20) }
                                        VStack(alignment:.leading,spacing:3) {
                                            Text(highlighted(line.text,query:model.transcriptQuery))
                                                .font(.system(size:12)).lineSpacing(3)
                                                .multilineTextAlignment(.leading).textSelection(.enabled)
                                                .fixedSize(horizontal:false,vertical:true)
                                                .padding(.horizontal,12).padding(.vertical,10)
                                                .foregroundStyle(Color.ink)
                                                .background(trailing ? Color.blue.opacity(0.11):Color.white.opacity(0.64),in:RoundedRectangle(cornerRadius:17))
                                                .contextMenu { Button("Copy paragraph") { model.copy(line.text) } }
                                            Button { model.jump(to:line.timestamp) } label: {
                                                HStack(spacing:5) {
                                                    if showSource { Text(TranscriptPresentation.sourceLabel(line.speaker)) }
                                                    Text(line.timestamp.formatted(date:.omitted,time:.standard)).monospacedDigit()
                                                    Image(systemName:"arrow.up.backward").font(.system(size:8,weight:.semibold))
                                                }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                                                    .padding(.horizontal,10).frame(minHeight:28).contentShape(Capsule())
                                            }.buttonStyle(.plain).help("Go to this moment")
                                        }
                                        if !trailing { Spacer(minLength:8) }
                                    }.id(line.id)
                                }
                            }.padding(.horizontal,2)
                        }.scrollIndicators(.never)
                        HStack(spacing:9) {
                            Image(systemName:"magnifyingglass").font(.system(size:13,weight:.medium)).foregroundStyle(Color.overlayControl)
                            TextField("Find in transcript",text:$model.transcriptQuery).textFieldStyle(.plain).font(.system(size:12))
                                .onSubmit { nextMatch(proxy:proxy) }
                            Button { nextMatch(proxy:proxy) } label: {
                                Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(Color.overlayControl).frame(width:36,height:36).contentShape(Circle())
                            }.buttonStyle(.plain).disabled(transcriptMatches.isEmpty).accessibilityLabel("Next transcript match").help("Next match")
                        }.padding(.leading,15).padding(.trailing,5).frame(height:44).frame(maxWidth:242)
                            .liquidGlass(radius:22,interactive:false)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.25)).allowsHitTesting(false))
                            .padding(.horizontal,10).padding(.bottom,4)

                    }
                }.frame(width:267)
            }
        }
    }
    private var transcriptMatches:[TranscriptLine] {
        let query = model.transcriptQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        return query.isEmpty ? []:visibleLines.filter { $0.text.localizedStandardContains(query) }
    }
    private func nextMatch(proxy:ScrollViewProxy) {
        let matches = transcriptMatches
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex(where:{$0.id == selectedLine}).map { ($0+1)%matches.count } ?? 0
        selectedLine = matches[index].id
        withAnimation(reduceMotion ? nil:.easeInOut(duration:0.2)) { proxy.scrollTo(selectedLine,anchor:.center) }
    }
    func highlighted(_ text:String,query:String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else {return result}
        var remaining = result.startIndex..<result.endIndex
        while let range = result[remaining].range(of:query,options:.caseInsensitive) {
            guard range.lowerBound < range.upperBound else { break }
            result[range].backgroundColor = .yellow.opacity(0.7)
            remaining = range.upperBound..<result.endIndex
        }
        return result
    }
}

/// Use AppKit directly: the system's SwiftUI VideoPlayer bridge can fail to
/// resolve AVPlayerView superclass metadata on newer macOS SDK/runtime pairs.
struct RecordingPlayerView:NSViewRepresentable {
    let player:AVPlayer
    func makeNSView(context:Context)->RoundedRecordingPlayer { RoundedRecordingPlayer() }
    func updateNSView(_ view:RoundedRecordingPlayer,context:Context) { view.setPlayer(player) }
    static func dismantleNSView(_ view:RoundedRecordingPlayer,coordinator:()) { view.setPlayer(nil) }
}

/// SwiftUI clipping does not reliably mask AVPlayerView's hosted video layer.
/// Fit and mask the native video rectangle itself, including letterboxed media.
final class RoundedRecordingPlayer:NSView {
    let video = AVPlayerView()
    private var sizeObservation:NSKeyValueObservation?
    private let videoMask = CAShapeLayer()
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer = true
        video.controlsStyle = .floating;video.videoGravity = .resizeAspect;video.wantsLayer = true
        video.layer?.masksToBounds = true;video.layer?.mask = videoMask
        addSubview(video)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsDefaultClipping:Bool { true }
    func setPlayer(_ player:AVPlayer?) {
        guard video.player !== player else { return }
        video.player?.pause();sizeObservation = nil;video.player = player
        sizeObservation = player?.currentItem?.observe(\.presentationSize,options:[.initial,.new]) { [weak self] _,_ in
            DispatchQueue.main.async { self?.needsLayout = true }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let size = video.player?.currentItem?.presentationSize ?? .zero
        if size.width > 0,size.height > 0 {
            let factor = min(bounds.width/size.width,bounds.height/size.height)
            let fitted = CGSize(width:size.width*factor,height:size.height*factor)
            video.frame = CGRect(x:(bounds.width-fitted.width)/2,y:(bounds.height-fitted.height)/2,width:fitted.width,height:fitted.height)
        } else { video.frame = bounds }
        CATransaction.begin();CATransaction.setDisableActions(true)
        videoMask.frame = video.bounds
        videoMask.path = CGPath(roundedRect:video.bounds,cornerWidth:22,cornerHeight:22,transform:nil)
        CATransaction.commit()
    }
}

private struct MeetingThumbnail:View {
    let url:URL
    @State private var image:NSImage?
    var body:some View {
        Group {
            if let image {
                Image(nsImage:image).resizable().aspectRatio(contentMode:.fit)
            } else { Color.clear.aspectRatio(1.5,contentMode:.fit) }
        }.frame(width:162).clipShape(RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).stroke(.white.opacity(0.9),lineWidth:2)).shadow(radius:8)
            .task(id:url) {
                guard let pixels = await MemoryImagePipeline.shared.image(at:url,maxPixels:600),!Task.isCancelled else { return }
                image = NSImage(cgImage:pixels,size:.zero)
            }
    }
}
