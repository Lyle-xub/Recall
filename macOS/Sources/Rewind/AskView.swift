import SwiftUI

struct AskView: View {
    @ObservedObject var model:AppModel
    @State private var question = ""
    @FocusState private var composing:Bool
    private var canSend:Bool { !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Image(systemName:"sparkles").foregroundStyle(.blue)
                Text("Ask Recall").font(.system(size:21,weight:.semibold,design:.rounded))
                Spacer()
                Button { model.settingsTab = "models"; model.settingsOpen = true } label: {
                    Label(model.settings.chat.model.isEmpty ? "Choose a model":model.settings.chat.model,systemImage:model.settings.chat.isLocal ? "desktopcomputer":"cloud")
                        .lineLimit(1).frame(maxWidth:220)
                }.buttonStyle(ComfortableButtonStyle()).font(.system(size:12))
                Button { model.cancelAsk(); model.messages = []; model.askError = nil; composing = true } label: {
                    Image(systemName:"square.and.pencil").frame(width:40,height:40)
                }.buttonStyle(.plain).help("New conversation").accessibilityLabel("New conversation")
            }
            HStack(spacing:8) {
                Label("\(model.appFilter ?? "All apps") · \(model.since.map { "Since " + $0.formatted(date:.abbreviated,time:.omitted) } ?? "All recorded history")",systemImage:"line.3.horizontal.decrease")
                if model.appFilter != nil || model.since != nil { Button("Clear scope") { model.appFilter = nil; model.since = nil }.buttonStyle(.plain).foregroundStyle(.blue) }
                Spacer()
            }.font(.system(size:11)).foregroundStyle(.secondary)
            if model.messages.isEmpty {
                VStack(spacing:15) {
                    Image(systemName:"sparkles").font(.system(size:34,weight:.light)).foregroundStyle(.blue.opacity(0.8))
                        .frame(width:78,height:78).background(.white.opacity(0.55),in:RoundedRectangle(cornerRadius:25))
                    Text("Ask your memory.").font(.system(size:28,weight:.medium,design:.rounded))
                    Text("Answers grounded in your recorded screens and conversations,\nwith sources you can return to.")
                        .font(.system(size:14)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators:false) {
                        LazyVStack(alignment:.leading,spacing:16) {
                            ForEach(model.messages) { message in messageView(message).id(message.id) }
                            if model.asking {
                                HStack(spacing:9) { ProgressView().controlSize(.small);Text(model.askStatus).font(.system(size:12)).foregroundStyle(.secondary) }.padding(.vertical,6)
                            }
                            Color.clear.frame(height:1).id("conversation-bottom")
                        }.padding(.vertical,8)
                    }.scrollIndicators(.never).defaultScrollAnchor(.bottom)
                        .onChange(of:model.messages.count) { _,_ in proxy.scrollTo("conversation-bottom",anchor:.bottom) }
                }
            }
            if let error = model.askError {
                HStack(alignment:.top,spacing:10) {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.system(size:12)).textSelection(.enabled);Spacer()
                    Button("Retry") { model.retryAsk() }.disabled(model.asking)
                }.padding(14).background(.white.opacity(0.65),in:RoundedRectangle(cornerRadius:14))
            }
            HStack(alignment:.bottom,spacing:12) {
                TextField("Ask about your memories…",text:$question,axis:.vertical).lineLimit(1...5).textFieldStyle(.plain)
                    .font(.system(size:16)).focused($composing).scrollIndicators(.never).padding(.vertical,12).onSubmit { submit() }
                Button { if model.asking { model.cancelAsk() } else { submit() } } label: {
                    Image(systemName:model.asking ? "stop.fill":"arrow.up").font(.system(size:17,weight:.semibold))
                        .foregroundStyle(.white).frame(width:46,height:46).background(canSend || model.asking ? Color.blue:Color.gray.opacity(0.45),in:Circle())
                }.buttonStyle(ComfortableButtonStyle()).disabled(!model.asking && !canSend)
                    .accessibilityLabel(model.asking ? "Stop answering":"Send question")
            }.padding(12).background(.white.opacity(0.8),in:RoundedRectangle(cornerRadius:24))
                .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.primary.opacity(0.06)))
            Label(model.settings.chat.isLocal ? "Local model · Memory text stays on this Mac":"Online model · Relevant memory text is sent to your chosen provider",systemImage:model.settings.chat.isLocal ? "lock.shield":"cloud")
                .font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth:1050).frame(maxWidth:.infinity)
            .background(.white.opacity(0.16),in:RoundedRectangle(cornerRadius:28)).onAppear { composing = true }
    }
    private func messageView(_ message:ChatMessage) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(message.role == "user" ? "You":"Recall").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                Spacer()
                if message.role != "user",!message.text.isEmpty {
                    Button { model.copy(message.text) } label: { Image(systemName:"doc.on.doc").frame(width:32,height:32) }.buttonStyle(.plain).foregroundStyle(Color.overlayControl).help("Copy answer").accessibilityLabel("Copy answer")
                }
            }
            if !message.text.isEmpty { Text(.init(message.text)).textSelection(.enabled).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading) }
            if !message.sources.isEmpty {
                Text("\(message.sources.count) sources").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        ForEach(Array(message.sources.enumerated()),id:\.element.id) { index,source in
                            Button { model.askOpen = false; model.select(source) } label: {
                                HStack(spacing:9) {
                                    AppBadge(name:source.appName,bundleID:source.bundleID,size:23)
                                    VStack(alignment:.leading,spacing:4) {
                                        Text("[\(index+1)] \(source.title.isEmpty ? source.appName:source.title)").lineLimit(1).font(.system(size:11,weight:.medium))
                                        Text(source.timeLabel).lineLimit(1).font(.system(size:10)).foregroundStyle(.secondary)
                                    }
                                }.padding(11).frame(width:235,alignment:.leading).background(.white.opacity(0.65),in:RoundedRectangle(cornerRadius:13))
                            }.buttonStyle(.plain).help("Open source \(index+1) in the timeline")
                        }
                    }
                }.scrollIndicators(.never)
            }
        }.padding(18).background(.white.opacity(message.role == "user" ? 0.25:0.5),in:RoundedRectangle(cornerRadius:20))
    }
    private func submit() { guard canSend,!model.asking else { return }; model.ask(question); question = "" }
}
