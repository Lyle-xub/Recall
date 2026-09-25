import SwiftUI
import AVKit

extension Color {
    static let ink = Color.primary
    static let glass = Color.white.opacity(0.25)
    static let overlayControl = Color.primary.opacity(0.62)
}

struct AppBadge: View {
    let name: String
    var bundleID: String? = nil
    var size: CGFloat = 23
    var body: some View {
        Group {
            if let image = AppIconCache.image(name:name,bundleID:bundleID) {
                Image(nsImage:image).resizable().interpolation(.high)
            } else {
                Image(systemName:name == "Imported" ? "photo.fill":"app.fill")
                    .resizable().scaledToFit().padding(size*0.16).foregroundStyle(.white)
                    .background(.blue,in:RoundedRectangle(cornerRadius:size*0.24))
            }
        }.frame(width:size,height:size).shadow(color:.black.opacity(0.12),radius:2,y:1).accessibilityLabel(name)
    }
}

struct RoundButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:16,weight:.medium)).foregroundStyle(Color.overlayControl).frame(width:50,height:50).liquidGlass(radius:25)
        }.buttonStyle(ComfortableButtonStyle()).help(label).accessibilityLabel(label)
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var searchEngaged = false
    @State private var archiveFocusedID: String?
    @Namespace private var searchGlassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expanded: Bool { model.searchPresented || model.askOpen || model.inspectorOpen }
    private var libraryHome: Bool { !model.settings.glassArchiveEnabled && !expanded && model.selected == nil && model.timelineCursor == nil }
    private var compactSearch: Bool { expanded || model.selected != nil }
    private var showSearchActions: Bool { searchEngaged || compactSearch }
    var body: some View {
        Group {
          if model.onboardingOpen {
              ZStack {
                  if model.launchFilmOpen {
                      LaunchFilmView(onStart:model.markLaunchFilmSeen,onEvent:{ event in
                          CaptureDiagnostics(root:model.store.root).write("Launch film: \(event)")
                      }) {
                          withAnimation(reduceMotion ? .easeOut(duration:0.2):.easeInOut(duration:0.8)) { model.launchFilmOpen = false }
                      }.id(model.launchFilmID).transition(.opacity).zIndex(1)
                  } else { OnboardingView(model:model).transition(.opacity).zIndex(0) }
              }
          } else { workspace }
        }
        .alert("Recall needs your attention",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error = nil}})) {
            if model.capturePermissionRequired {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    model.hideOverlay(); model.capturePermissionRequired = false
                }
            }
            Button("OK") {model.error = nil}
        } message: { Text(model.error ?? "") }
    }
    private var workspace: some View {
        GeometryReader { geo in
            let top = model.desktopInsets.top
            ZStack {
                ArchiveBackdrop(appearance:model.settings.appearance).ignoresSafeArea().allowsHitTesting(false)
                DesktopClickShield {
                    searchFocused = false
                    if archiveFocusedID != nil {
                        withAnimation(reduceMotion ? nil:.spring(response:0.76,dampingFraction:0.86)) { archiveFocusedID = nil }
                    } else { model.dismissTimeline() }
                }.ignoresSafeArea()
                if model.settings.glassArchiveEnabled {
                ArchiveStackView(model:model,focusedID:$archiveFocusedID)
                    .opacity(!expanded && model.selected == nil && model.timelineCursor == nil ? 1:0)
                    .scaleEffect(expanded || model.selected != nil ? 0.96:1)
                    .allowsHitTesting(!expanded && model.selected == nil && model.timelineCursor == nil)
                    .accessibilityHidden(expanded || model.selected != nil || model.timelineCursor != nil)
                }
                if !expanded,let frame = model.selected {
                    history(frame, size:geo.size).transition(.opacity)
                }
                if model.searchPresented { results.padding(.top,top+120).padding(.bottom,28) }
                else if model.askOpen { AskView(model:model).padding(.horizontal,60).padding(.top,top+118).padding(.bottom,30) }
                else if model.inspectorOpen, let frame = model.selected {
                    DetailView(model:model,frame:frame).padding(.horizontal,40).padding(.top,top+110).padding(.bottom,32)
                } else {
                    if model.selected != nil { historyActions.position(x:geo.size.width/2,y:top+108) }
                    if model.total == 0 { recordingPrompt.position(x:geo.size.width/2,y:geo.size.height*0.425+106) }
                    else if model.timelineCursor != nil,model.selected == nil {
                        Label("No screen captured at this time",systemImage:"clock")
                            .font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,12)
                            .liquidGlass(radius:18,interactive:false).position(x:geo.size.width/2,y:geo.size.height*0.425+90)
                    }
                    archiveCaptions(size:geo.size,top:top)
                }
                if showSearchActions {
                    searchToolbar(width:min(1020,geo.size.width-196))
                        .frame(height:58)
                        .position(x:geo.size.width/2,y:top+43)
                        .transition(.opacity.combined(with:.scale(scale:0.94)))
                        .zIndex(5)
                }
                HStack {
                    if expanded || model.selected != nil || showSearchActions || archiveFocusedID != nil {
                        BareIconButton(symbol:"arrow.left",label:model.settings.glassArchiveEnabled ? "返回档案":"返回记忆库") { goBack() }.frame(width:showSearchActions ? 58:34,height:58)
                    } else {
                        VStack(alignment:.leading,spacing:3) {
                            Text("RECALL").font(.system(size:geo.size.width < 1050 ? 32:42,weight:.heavy)).tracking(-1.5)
                            Text("MEMORY ARCHIVE   /   私人记忆终端")
                                .font(.system(size:10,weight:.medium)).tracking(1.7)
                        }.foregroundStyle(Color.primary.opacity(0.92))
                    }
                    Spacer()
                    if !showSearchActions {
                        HStack(spacing:geo.size.width < 1050 ? 9:18) {
                            archiveNavigation("记忆库",symbol:"folder",compact:geo.size.width < 1050) { model.query = ""; model.showSearch() }
                            archiveNavigation("搜索",symbol:"magnifyingglass",compact:geo.size.width < 1050) { searchEngaged = true; searchFocused = true }
                            ThemeTogglePill(appearance:model.settings.appearance) { model.toggleAppearance() }
                            BareIconButton(symbol:"slider.horizontal.3",label:"Settings") { model.settingsOpen = true }
                            Rectangle().fill(Color.primary.opacity(0.16)).frame(width:1,height:16)
                            Text("\(model.total)").font(.system(size:13,weight:.medium).monospacedDigit()).fixedSize().foregroundStyle(Color.overlayControl)
                            BareIconButton(symbol:model.recordingRequested ? "pause":"play",label:model.recordingActionTitle,size:13) { model.toggleRecording() }
                            menu
                            BareIconButton(symbol:"xmark",label:"关闭 Recall",size:11) { model.hideOverlay() }
                        }.transition(.opacity)
                    }
                }.padding(.horizontal,34).position(x:geo.size.width/2,y:top+(showSearchActions ? 43:59))
                Text("● \(model.apps.count) 个应用 · \(model.total) 条记忆 · 本地索引")
                    .font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,40)
                    .position(x:geo.size.width/2,y:top+131).allowsHitTesting(false)
                    .opacity(showSearchActions || expanded || model.selected != nil ? 0:1)
                if let toast = model.toast {
                    Text(toast).font(.system(size:12,weight:.medium)).padding(.horizontal,19).padding(.vertical,11)
                        .liquidGlass(radius:20).position(x:geo.size.width/2,y:geo.size.height-240).allowsHitTesting(false)
                }
            }
            .clipped()
            .animation(reduceMotion ? nil:.spring(response:0.64,dampingFraction:0.9),value:expanded)
            .animation(reduceMotion ? nil:.spring(response:0.64,dampingFraction:0.9),value:model.selected?.id)
            .animation(reduceMotion ? nil:.spring(response:0.42,dampingFraction:0.9),value:compactSearch)
            .animation(reduceMotion ? nil:.spring(response:0.58,dampingFraction:0.64),value:showSearchActions)
        }
        .font(.system(size:14)).buttonStyle(ComfortableButtonStyle()).controlSize(.large).frame(minWidth:800,minHeight:600)
        .preferredColorScheme(ArchiveTone.colorScheme(model.settings.appearance))
        .task(id:libraryHome) {
            if libraryHome { model.showSearch() }
        }
        .onChange(of:model.settings.glassArchiveEnabled) { _,enabled in
            archiveFocusedID = nil;searchFocused = false;searchEngaged = false
            model.returnToDesktop()
            if !enabled { model.showSearch() }
        }
        .sheet(isPresented:$model.settingsOpen) { SettingsView(model:model) }
        .sheet(isPresented:$model.usageOpen) { AppUsageView(model:model) }
        .onChange(of:model.query) { _,value in if !value.isEmpty { searchEngaged = true }; model.debounceSearch() }
        .onChange(of:model.appFilter) { _,_ in model.reload() }
        .onChange(of:model.starredOnly) { _,_ in model.reload() }
        .onChange(of:model.since) { _,_ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("RewindPrepareSearch"))) { _ in searchEngaged = true; searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("RewindFocusSearch"))) { _ in searchEngaged = true; searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for:.recallGoBack)) { _ in goBack() }
        .onExitCommand { goBack() }
    }
    private func goBack() {
        let wasSearching = searchEngaged
        searchFocused = false; searchEngaged = false
        if archiveFocusedID != nil,!expanded,model.selected == nil {
            withAnimation(reduceMotion ? nil:.spring(response:0.76,dampingFraction:0.86)) { archiveFocusedID = nil }
        }
        else if !model.settings.glassArchiveEnabled,model.searchPresented,!model.askOpen,!model.inspectorOpen,model.selected == nil,model.query.isEmpty,model.appFilter == nil,model.since == nil,!model.starredOnly,!model.trash {
            model.hideOverlay()
        }
        else if model.inspectorOpen { model.inspectorOpen = false }
        else if expanded || model.selected != nil { model.returnToDesktop() }
        else if !wasSearching { model.hideOverlay() }
    }
    private func archiveNavigation(_ title:String,symbol:String,compact:Bool,action:@escaping ()->Void)->some View {
        Button(action:action) {
            HStack(spacing:7) {
                Image(systemName:symbol)
                if !compact { Text(title).fixedSize() }
            }.font(.system(size:12,weight:.medium))
                .foregroundStyle(Color.overlayControl).padding(.vertical,9)
                .accessibilityLabel(title)
                .contentShape(Rectangle())
        }.buttonStyle(ComfortableButtonStyle())
    }
    private func searchToolbar(width:CGFloat)->some View {
        SearchGlassGroup {
          HStack(spacing:18) {
            searchBar.frame(width:showSearchActions ? width-380:min(860,width),height:showSearchActions ? 58:72)
                .modifier(SearchGlassSurface(id:"search",namespace:searchGlassNamespace,radius:showSearchActions ? 29:36))
                .phaseAnimator([0,1,2],trigger:showSearchActions) { content,phase in
                    content.scaleEffect(x:!reduceMotion && phase == 1 ? 0.975:1,y:!reduceMotion && phase == 1 ? 1.045:1,anchor:.trailing)
                } animation: { phase in
                    reduceMotion ? nil:.spring(response:phase == 1 ? 0.18:0.42,dampingFraction:phase == 1 ? 0.72:0.53)
                }
                .shadow(color:.black.opacity(0.15),radius:22,y:10)
                .background(SearchClickObserver { searchEngaged = true })
            if showSearchActions {
                    Menu {
                        Button("All applications") { model.appFilter = nil; model.showSearch() }
                        Divider()
                        ForEach(model.apps,id:\.self) { app in
                            Button { model.appFilter = app; model.showSearch() } label: {
                                Label(app,systemImage:model.appFilter == app ? "checkmark":"app")
                            }
                        }
                    } label: {
                        Image(systemName:"square.grid.2x2").font(.system(size:20,weight:.regular)).foregroundStyle(Color.overlayControl).frame(width:58,height:58)
                    }.menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).frame(width:58,height:58)
                        .modifier(SearchGlassSurface(id:"applications",namespace:searchGlassNamespace,radius:29))
                        .transition(dropletTransition(0)).help("Filter by application").accessibilityLabel("Filter by application")
                    searchAction(symbol:model.starredOnly ? "star.fill":"star",label:"Starred memories",id:"starred",index:1,selected:model.starredOnly) {
                        model.starredOnly.toggle(); model.showSearch()
                    }
                    searchAction(symbol:"sparkles",label:"Ask Recall",id:"ask",index:2,selected:model.askOpen) {
                        model.back(); model.searchPresented = false; model.askOpen = true; searchFocused = false
                    }
                    searchAction(symbol:"chart.bar.xaxis",label:"App usage",id:"usage",index:3) { searchFocused = false; model.usageOpen = true }
                    searchAction(symbol:"slider.horizontal.3",label:"Settings",id:"settings",index:4) { model.settingsOpen = true }
            }
          }.frame(width:width)
        }
    }
    private func dropletTransition(_ index:Int)->AnyTransition {
        guard !reduceMotion else { return .identity }
        let emergence = AnyTransition.offset(x:-CGFloat(53+76*index),y:4)
            .combined(with:.scale(scale:0.38,anchor:.leading)).combined(with:.opacity)
        return .asymmetric(insertion:emergence.animation(.spring(response:0.56,dampingFraction:0.57).delay(Double(index)*0.035)),
                           removal:emergence.animation(.spring(response:0.3,dampingFraction:0.86)))
    }
    private func searchAction(symbol:String,label:String,id:String,index:Int,selected:Bool = false,action:@escaping ()->Void)->some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:20,weight:.regular)).foregroundStyle(Color.overlayControl)
                .frame(width:58,height:58)
        }.buttonStyle(ComfortableButtonStyle())
            .modifier(SearchGlassSurface(id:id,namespace:searchGlassNamespace,radius:29))
            .overlay(alignment:.bottom) { if selected { Circle().fill(Color.accentColor).frame(width:4,height:4).padding(.bottom,6).allowsHitTesting(false) } }
            .transition(dropletTransition(index)).help(label).accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected:[])
    }
    private var searchBar: some View {
        HStack(spacing:14) {
            Image(systemName:"magnifyingglass").font(.system(size:23,weight:.medium))
            TextField(showSearchActions ? "Search memories":"Search anything you’ve seen, said, or heard",text:$model.query)
                .textFieldStyle(.plain).font(.system(size:showSearchActions ? 20:23,weight:.regular))
                .focused($searchFocused).onSubmit { model.showSearch() }
                .accessibilityLabel("Search memories")
            if !model.query.isEmpty {
                Button { model.query = ""; model.showSearch() } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(ComfortableButtonStyle()).help("Clear search")
            }
        }.padding(.horizontal,24).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var menu: some View {
        Menu {
            Button(model.recordingActionTitle,systemImage:model.recordingRequested ? "pause.circle":"record.circle") {model.toggleRecording()}.disabled(model.working)
            Divider()
            Button("Browse all memories",systemImage:"square.grid.2x2") {model.query = "";model.showSearch()}
            Button("Ask Recall",systemImage:"sparkles") {model.back();model.searchPresented = false;model.askOpen = true;searchFocused = false}
            Button("App usage…",systemImage:"chart.bar.xaxis") {model.usageOpen = true}
            Button("Settings…",systemImage:"gearshape") {model.settingsOpen = true}
            Button("Welcome to Recall…",systemImage:"sparkle") {model.showOnboarding()}
            Button("Jump to date…",systemImage:"calendar") {model.searchPresented = false;model.askOpen = false;model.timelineJumpOpen = true}
            Divider()
            Button("Import images…",systemImage:"square.and.arrow.down") {model.importImages()}
            Button("Export current results…",systemImage:"square.and.arrow.up") {model.exportMemories()}
            Button(model.trash ? "Leave Trash":"Trash",systemImage:"trash") {model.trash.toggle();model.back();model.searchPresented = true;model.reload()}
            Button("Show data folder",systemImage:"folder") {NSWorkspace.shared.open(model.store.root)}
            Divider()
            Button("Quit Recall") {NSApplication.shared.terminate(nil)}.keyboardShortcut("q")
        } label: {
            Image(systemName:"ellipsis").font(.system(size:17,weight:.semibold)).foregroundStyle(Color.overlayControl.opacity(0.78)).frame(width:34,height:34)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(width:34,height:34).help("Recall menu").accessibilityLabel("Recall menu")
    }
    private func archiveCaptions(size:CGSize,top:CGFloat)->some View {
        let style = Font.system(size:10,weight:.medium)
        return Group {
            Text("LOCAL COLLECTION · \(model.apps.count) APPS / \(model.total) MEMORIES")
                .frame(maxWidth:.infinity,alignment:.leading)
            Text(size.width < 1050 ? "\(model.settings.appearance.label) · LOCAL":"\(model.settings.appearance.label) MODE · \(model.recordingStatusTitle.uppercased())")
                .frame(maxWidth:.infinity,alignment:.trailing)
        }
        .font(style).tracking(1.8).foregroundStyle(.secondary.opacity(0.85))
        .padding(.horizontal,40)
        .position(x:size.width/2,y:size.height-34)
        .allowsHitTesting(false)
    }
    private var recordingPrompt: some View {
        VStack(spacing:14) {
            Button {model.toggleRecording()} label: {
                HStack(spacing:8) {
                    Circle().fill(model.recording ? .red:Color.primary).frame(width:7,height:7)
                    Text(model.working ? "Updating recording…":model.recordingAutomaticallyPaused ? "Ready · recording resumes on close":model.recording ? "Recording · pause":"Start recording on this Mac")
                }.font(.system(size:13,weight:.medium)).padding(.horizontal,20).padding(.vertical,12).liquidGlass(radius:22)
            }.buttonStyle(ComfortableButtonStyle()).disabled(model.working)
            Text("\(model.settings.shortcuts.open.label) to rewind · Screens stay on this Mac").font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
    private func history(_ frame:MemoryFrame,size:CGSize) -> some View {
        HistoryMemoryPreview(url:model.store.root.appendingPathComponent(frame.imagePath),regions:frame.regions,screen:size,topInset:model.desktopInsets.top)
    }
    private var historyActions: some View {
        HStack(spacing:6) {
            if let frame = model.selected {
                AppBadge(name:frame.appName,bundleID:frame.bundleID,size:20)
                VStack(alignment:.leading,spacing:2) {
                    Text("Recorded · \(frame.timestamp.formatted(date:.omitted,time:.standard))").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                    Text(frame.title).lineLimit(1).frame(maxWidth:210,alignment:.leading).font(.system(size:12,weight:.medium))
                }
                Divider().frame(height:16)
                Button {model.star(frame)} label: {Image(systemName:frame.starred ? "star.fill":"star")}.help("Star this memory")
                Button {model.copy(frame.text)} label: {Image(systemName:"doc.on.doc")}.help("Copy all recognized text")
                Button {model.inspectorOpen = true;searchFocused = false} label: {Image(systemName:"sidebar.right")}.help("Recording, meeting and transcript")
                if !model.query.isEmpty {Button {model.showSearch()} label: {Image(systemName:"square.grid.2x2")}.help("Back to search results")}
            }
        }.foregroundStyle(Color.overlayControl).symbolRenderingMode(.monochrome)
            .buttonStyle(ComfortableButtonStyle()).padding(.horizontal,12).frame(height:52).liquidGlass(radius:26)
    }
    private var results: some View {
        VStack(spacing:24) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:12) {
                    filterButton("Starred",selected:model.starredOnly) {model.starredOnly.toggle()} icon: {Image(systemName:"star.fill").foregroundStyle(.cyan)}
                    ForEach(model.apps,id:\.self) { app in
                        filterButton(app,selected:model.appFilter == app) {model.appFilter = model.appFilter == app ? nil:app} icon: {AppBadge(name:app,bundleID:model.frames.first(where:{$0.appName == app})?.bundleID,size:24)}
                    }
                    if model.since != nil { Button("Clear date filter") {model.since = nil}.buttonStyle(ComfortableButtonStyle()).padding(12).liquidGlass(radius:18) }
                }.padding(.horizontal,48).padding(.vertical,6)
            }.scrollIndicators(.never).frame(height:62)
            if model.searchLoading && model.frames.isEmpty {
                ProgressView("Searching memories…").frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if model.frames.isEmpty {
                VStack(spacing:13) {
                    Image(systemName:model.total == 0 ? "record.circle":"magnifyingglass").font(.system(size:36,weight:.light))
                    Text(model.total == 0 ? "Your memories start here":"No memories found").font(.system(size:23,weight:.medium))
                    Text(model.total == 0 ? "Start recording to search your real screen history.":"Try another phrase or change the app filter.").foregroundStyle(.secondary)
                    Button(model.total == 0 ? "Start recording":"Clear filters") {
                        if model.total == 0 {model.toggleRecording()} else {model.query = "";model.appFilter = nil;model.since = nil;model.starredOnly = false;model.showSearch()}
                    }.padding(.horizontal,17).padding(.vertical,11).liquidGlass(radius:20).buttonStyle(ComfortableButtonStyle())
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView(showsIndicators:false) {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:26),count:3),alignment:.leading,spacing:28) {
                        ForEach(model.frames) { frame in MemoryCard(model:model,frame:frame) }
                    }.padding(.horizontal,42).padding(.top,6).padding(.bottom,24)
                    if model.searchHasMore {Button(model.searchLoading ? "Loading…":"Load more memories") {model.loadMore()}.disabled(model.searchLoading).padding()}
                }.scrollIndicators(.never).id("\(model.query)|\(model.appFilter ?? "")|\(model.starredOnly)|\(model.since?.timeIntervalSince1970 ?? 0)")
            }
        }
    }
    private func filterButton<Icon:View>(_ title:String,selected:Bool,action:@escaping ()->Void,@ViewBuilder icon:()->Icon) -> some View {
        Button(action:action) {
            HStack(spacing:10) {icon();Text(title).font(.system(size:14,weight:.medium))}
                .frame(minWidth:100).padding(.horizontal,17).frame(height:47)
                .background(selected ? Color.accentColor.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:19))
                .liquidGlass(radius:19)
                .overlay(RoundedRectangle(cornerRadius:19).strokeBorder(selected ? Color.accentColor.opacity(0.6):.clear,lineWidth:1.5))
        }.buttonStyle(ComfortableButtonStyle())
    }
}

struct MemoryCard: View {
    @ObservedObject var model: AppModel
    let frame: MemoryFrame
    @State private var hovered = false
    @State private var thumbnail: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {model.select(frame)} label: {
            VStack(alignment:.leading,spacing:12) {
                GeometryReader { geo in
                    let plan = MemorySearchPlan(model.query)
                    ZStack(alignment:.topLeading) {
                        if let image = thumbnail {
                            Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(width:geo.size.width,height:geo.size.height)
                            let ratio = image.size.width/image.size.height
                            let w = min(geo.size.width,geo.size.height*ratio), h = w/ratio
                            ForEach(frame.regions.filter { plan.highlights($0.text) }) { region in
                                RoundedRectangle(cornerRadius:3).fill(.yellow.opacity(0.26)).overlay(RoundedRectangle(cornerRadius:3).stroke(.yellow.opacity(0.9),lineWidth:1.5))
                                    .frame(width:region.width*w,height:region.height*h)
                                    .offset(x:(geo.size.width-w)/2+region.x*w,y:(geo.size.height-h)/2+region.y*h)
                            }
                        }
                        if hovered {
                            VStack {Spacer();HStack {Spacer();Text("Rewind to this moment").font(.system(size:11,weight:.medium)).padding(.horizontal,13).padding(.vertical,8).liquidGlass(radius:18);Spacer()}.padding(.bottom,12)}
                        }
                    }.clipped().clipShape(RoundedRectangle(cornerRadius:19))
                }.aspectRatio(1.6,contentMode:.fit).background(.black.opacity(0.08),in:RoundedRectangle(cornerRadius:19))
                HStack(alignment:.center,spacing:10) {
                    AppBadge(name:frame.appName,bundleID:frame.bundleID,size:29)
                    VStack(alignment:.leading,spacing:4) {
                        Text(frame.title.isEmpty ? frame.appName:frame.title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                        Text(frame.timeLabel).font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                    if frame.starred {Image(systemName:"star.fill").foregroundStyle(.yellow)}
                }.padding(.horizontal,3).padding(.bottom,3)
            }.padding(10).liquidGlass(radius:29,interactive:true)
                .overlay(RoundedRectangle(cornerRadius:29).strokeBorder(.white.opacity(hovered ? 0.65:0.12),lineWidth:1))
        }.buttonStyle(ComfortableButtonStyle()).onHover {hovered = $0}
            .task(id:frame.imagePath) {
                guard let pixels = await MemoryImagePipeline.shared.image(at:model.store.root.appendingPathComponent(frame.imagePath),maxPixels:900),!Task.isCancelled else { return }
                thumbnail = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
            }
            .scaleEffect(hovered && !reduceMotion ? 1.018:1)
            .animation(reduceMotion ? nil:.spring(response:0.3,dampingFraction:0.8),value:hovered)
            .accessibilityLabel("\(frame.title), \(frame.appName), \(frame.timeLabel)")
            .contextMenu {
                Button(frame.starred ? "Remove star":"Star") {model.star(frame)}
                Button("Copy recognized text") {model.copy(frame.text)}
                if let source = frame.sourceURL,let url = URL(string:source),["https","http"].contains(url.scheme?.lowercased() ?? "") {Button("Open source") {NSWorkspace.shared.open(url)}}
                if frame.deletedAt == nil {Button("Move to Trash") {model.delete(frame)}} else {Button("Restore") {model.restore(frame)}}
            }
    }
}

private struct HistoryMemoryPreview: View {
    let url:URL
    let regions:[TextRegion]
    let screen:CGSize
    let topInset:CGFloat
    @State private var imageSize:CGSize?
    var body: some View {
        let rect = HistoryPreviewGeometry.rect(screen:screen,image:imageSize ?? screen,topInset:topInset)
        SelectableMemoryImage(url:url,regions:regions,maxPixels:2048,onImageSize:{ size in if imageSize != size { imageSize = size } })
            .frame(width:rect.width,height:rect.height)
            .background(.black.opacity(0.08),in:RoundedRectangle(cornerRadius:22))
            .clipShape(RoundedRectangle(cornerRadius:22))
            .overlay(RoundedRectangle(cornerRadius:22).strokeBorder(.white.opacity(0.7),lineWidth:1.5).allowsHitTesting(false))
            .shadow(color:.black.opacity(0.26),radius:28,y:12)
            .position(x:rect.midX,y:rect.midY)
    }
}
