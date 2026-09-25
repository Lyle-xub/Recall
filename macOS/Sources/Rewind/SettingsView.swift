import SwiftUI
import ScreenCaptureKit

private enum SettingsPage: String, CaseIterable {
    case recording, permissions, models, storage, shortcuts
    var title: String { switch self { case .recording: "Recording"; case .permissions: "Permissions"; case .models: "Models"; case .storage: "Storage"; case .shortcuts: "Shortcuts" } }
    var symbol: String { switch self { case .recording: "record.circle"; case .permissions: "lock.shield"; case .models: "sparkles"; case .storage: "internaldrive"; case .shortcuts: "keyboard" } }
    var subtitle: String { switch self {
        case .recording: "Choose what Recall remembers."
        case .permissions: "Control access to your screen and microphone."
        case .models: "Intelligence that works your way."
        case .storage: "Your memories, under your control."
        case .shortcuts: "A quick way back to any moment."
    } }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: AppSettings
    @State private var chatKey = ""
    @State private var speechKey = ""
    @State private var status = ""
    @State private var saving = false
    @State private var connecting = false
    @State private var confirmEmptyTrash = false
    @State private var cleanupOpen = false
    @State private var displays: [SCDisplay] = []
    @State private var excluded = ""
    @State private var detectedModels: [String] = []
    @State private var storageUsage: StorageUsage?
    @State private var storageLoading = false
    @State private var storageError = ""
    @State private var storageRefresh = UUID()
    @State private var microphonePermission = CapturePermissions.microphone
    @State private var screenPermission = CapturePermissions.screen
    @State private var requestingMicrophone = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var page: SettingsPage { SettingsPage(rawValue:model.settingsTab) ?? .recording }
    init(model:AppModel) { self.model = model; _draft = State(initialValue:model.settings) }
    var body: some View {
        VStack(spacing:0) {
            header
            categories
            ScrollView(showsIndicators:false) {
                VStack(alignment:.leading,spacing:16) {
                    switch page {
                    case .recording: recording
                    case .permissions: permissions
                    case .models: models
                    case .storage: storage
                    case .shortcuts: shortcuts
                    }
                }.padding(.horizontal,24).padding(.top,18).padding(.bottom,24).frame(maxWidth:.infinity,alignment:.leading)
            }.scrollIndicators(.never).id(page)
            footer
        }
        .frame(width:660,height:min(790,max(520,(model.window?.screen?.visibleFrame.height ?? 890)-80)))
        // The native sheet owns its outer corners. A second rounded glass shell
        // caused the doubled frame and mismatched corners on macOS 26.
        .background(.white)
        .presentationBackground(.white)
        .preferredColorScheme(.light)
        .font(.system(size:13)).controlSize(.large)
        .sheet(isPresented:$cleanupOpen,onDismiss:{ storageRefresh = UUID() }) {
            StorageCleanupView(model:model) { message in status = message;storageRefresh = UUID() }
        }
        .confirmationDialog("Permanently delete every memory in Trash?",isPresented:$confirmEmptyTrash,titleVisibility:.visible) {
            Button("Delete permanently",role:.destructive) { do { let count = try model.store.emptyTrash(); model.reload(); status = "Deleted \(count) memories and their unused recordings"; storageRefresh = UUID() } catch { status = error.localizedDescription } }
        } message: { Text("This removes screenshots, text and recordings that are no longer used by any retained memory. It cannot be undone.") }
        .task(id:"\(page.rawValue)-\(storageRefresh)") {
            guard page == .storage else { return }
            storageLoading = true; storageError = ""
            let root = model.store.root, models = BuiltinModels.shared.root
            let worker = Task.detached(priority:.utility) { try StorageUsageReader.scan(root:root,modelRoot:models) }
            defer { storageLoading = false }
            do {
                let result = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                guard !Task.isCancelled else { return }; storageUsage = result
            } catch is CancellationError {} catch { storageError = error.localizedDescription }
        }
        .onAppear { chatKey = SecretStore.read("chat"); speechKey = SecretStore.read("transcription"); excluded = draft.excludedApps.joined(separator:"\n") }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .onChange(of:model.settingsTab) { _,_ in refreshPermissions() }
        .onReceive(model.storageOptimizer.$savedBytes.dropFirst().throttle(for:.seconds(2),scheduler:RunLoop.main,latest:true)) { _ in storageRefresh = UUID() }
    }
    private var categories: some View {
        HStack(spacing:4) {
            ForEach(SettingsPage.allCases,id:\.self) { item in
                Button {
                    withAnimation(reduceMotion ? nil:.easeInOut(duration:0.16)) { model.settingsTab = item.rawValue }
                } label: {
                    VStack(spacing:6) {
                        Image(systemName:item.symbol).font(.system(size:17))
                        Text(item.title).font(.system(size:11,weight:page == item ? .semibold:.medium))
                    }.frame(maxWidth:.infinity).frame(height:60).contentShape(RoundedRectangle(cornerRadius:16))
                        .background(page == item ? Color.accentColor.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:16))
                        .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(page == item ? Color.accentColor.opacity(0.16):Color.clear))
                }.buttonStyle(.plain).foregroundStyle(page == item ? Color.accentColor:Color.secondary)
                    .accessibilityAddTraits(page == item ? .isSelected:[])
            }
        }.padding(5).background(Color(red:0.97,green:0.98,blue:1),in:RoundedRectangle(cornerRadius:21))
            .overlay(RoundedRectangle(cornerRadius:21).strokeBorder(Color.blue.opacity(0.06)))
            .padding(.horizontal,24).padding(.bottom,4)
    }
    private var header: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:4) {
                Text("Settings").font(.system(size:23,weight:.semibold,design:.rounded))
                Text(page.subtitle).font(.system(size:12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).frame(width:44,height:44).liquidGlass(radius:22) }
                .buttonStyle(.plain).accessibilityLabel("Close settings").help("Close settings")
        }.padding(24)
    }
    private var footer: some View {
        HStack(spacing:12) {
            Text(status.isEmpty ? "Changes apply when you save.":status).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
            Button("Cancel") { dismiss() }.buttonStyle(SettingsActionStyle())
            Button(saving ? "Saving…":"Save changes") { save() }.buttonStyle(SettingsActionStyle(prominent:true)).disabled(saving || shortcutIssue != nil)
        }.padding(.horizontal,24).padding(.vertical,16)
            .background(.white).overlay(alignment:.top) { Rectangle().fill(.primary.opacity(0.06)).frame(height:1) }
    }
    private var recording: some View {
        Group {
            SettingsCard {
                HStack(spacing:14) {
                    Image(systemName:model.recording ? "record.circle.fill":"pause.circle")
                        .font(.system(size:26)).foregroundStyle(model.recording ? Color.red:Color.secondary)
                        .frame(width:48,height:48).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
                    VStack(alignment:.leading,spacing:4) {
                        Text(model.recordingStatusTitle).font(.system(size:15,weight:.semibold))
                        Text(model.indexingIssue ?? model.recordingStatusDetail).font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.recordingActionTitle) { model.toggleRecording() }.disabled(model.working).buttonStyle(SettingsActionStyle(prominent:!model.recordingRequested))
                }
            }
            SettingsCard(title:"Appearance",symbol:"dock.rectangle") {
                SettingsRow(title:"Overlay appearance",detail:"暖昼 ivory archive or 深夜 dark scene.") {
                    Picker("Overlay appearance",selection:$draft.appearance) {
                        Text("暖昼").tag(OverlayAppearance.warmDay)
                        Text("深夜").tag(OverlayAppearance.deepNight)
                    }.labelsHidden().pickerStyle(.segmented).frame(width:154)
                }
                Divider().opacity(0.5)
                SettingsToggle(title:"玻璃档案首页",detail:"按日期浏览玻璃卡片与波浪动效；关闭后使用记忆库。",value:$draft.glassArchiveEnabled)
                Divider().opacity(0.5)
                SettingsToggle(title:"Show Recall in Dock",detail:"Keep an app icon in the Dock and app switcher.",value:$draft.showDockIcon)
                Text("The menu bar icon and shortcuts remain available either way.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            SettingsCard(title:"Screen capture",symbol:"display") {
                SettingsRow(title:"Capture interval",detail:"How often a screen is saved.") {
                    Picker("Capture interval",selection:$draft.captureInterval) { Text("2 seconds").tag(2.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0) }.labelsHidden().frame(width:154)
                }
                Divider().opacity(0.5)
                SettingsRow(title:"Display") {
                    Picker("Display",selection:Binding(get:{draft.displayID ?? 0},set:{draft.displayID = $0 == 0 ? nil:$0})) {
                        Text("Primary display").tag(UInt32(0))
                        if let id = draft.displayID,!displays.contains(where:{$0.displayID == id}) { Text("Display \(id)").tag(id) }
                        ForEach(displays,id:\.displayID) { d in Text("\(d.width) × \(d.height)").tag(d.displayID) }
                    }.labelsHidden().frame(width:154)
                    Button { Task { do { displays = try await CaptureEngine.displays() } catch { status = error.localizedDescription } } } label: { Image(systemName:"arrow.clockwise").frame(width:44,height:44) }.buttonStyle(.plain).help("Refresh displays").accessibilityLabel("Refresh displays")
                }
                Divider().opacity(0.5)
                SettingsToggle(title:"Open at login",detail:"Recording stays paused until you start it.",value:$draft.launchAtLogin)
            }
            SettingsCard(title:"Audio",symbol:"waveform") {
                SettingsToggle(title:"System audio",detail:"Remember meetings and audio playing on this Mac.",value:$draft.systemAudio)
                Divider().opacity(0.5)
                SettingsToggle(title:"Microphone",detail:"Include your voice in recordings.",value:$draft.microphone)
                Button { model.settingsTab = "permissions" } label: {
                    Label("Manage permissions",systemImage:"lock.shield")
                }.buttonStyle(SettingsActionStyle())
                Text("Audio stays on this Mac. Transcription starts after each 5-minute segment, or when you pause.").font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            SettingsCard(title:"Excluded applications",symbol:"eye.slash") {
                Text("One bundle identifier per line. These apps are never captured.").font(.system(size:11)).foregroundStyle(.secondary)
                TextEditor(text:$excluded).font(.system(size:12,design:.monospaced)).scrollContentBackground(.hidden).scrollIndicators(.never).padding(10).frame(height:100)
                    .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12)).accessibilityLabel("Excluded applications")
            }
        }
    }
    private var permissions: some View {
        Group {
            SettingsCard {
                permissionHeading("Screen & system audio",symbol:"display",allowed:screenPermission,status:screenPermission ? "Allowed":"Not allowed")
                Text("Capture the display and, when enabled in Recording, audio playing on your Mac.").font(.system(size:12)).foregroundStyle(.secondary)
                HStack {
                    Button(screenPermission ? "Open System Settings":"Allow screen recording") {
                        if screenPermission { openPermissionSettings(microphone:false) }
                        else {
                            _ = CGRequestScreenCaptureAccess(); refreshPermissions()
                            if !screenPermission { openPermissionSettings(microphone:false) }
                        }
                    }.buttonStyle(SettingsActionStyle(prominent:!screenPermission))
                    Spacer()
                }
            }
            SettingsCard {
                permissionHeading("Microphone",symbol:"mic",allowed:microphonePermission == .authorized,status:microphonePermission.label)
                Text("Allow access to record your voice. Choose whether to include it in Recording settings.").font(.system(size:12)).foregroundStyle(.secondary)
                HStack {
                    Button(requestingMicrophone ? "Requesting…":microphonePermission == .notDetermined ? "Allow microphone":"Open System Settings") {
                        if microphonePermission == .notDetermined {
                            requestingMicrophone = true
                            Task {
                                do { try await CapturePermissions.ensureMicrophone(enabled:true); status = "Microphone access allowed." }
                                catch { status = error.localizedDescription }
                                requestingMicrophone = false; refreshPermissions()
                            }
                        } else { openPermissionSettings(microphone:true) }
                    }.buttonStyle(SettingsActionStyle(prominent:microphonePermission != .authorized))
                        .disabled(requestingMicrophone || microphonePermission == .restricted)
                    Spacer()
                }
            }
            HStack {
                Text("System permissions apply immediately.").font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh status",systemImage:"arrow.clockwise") { refreshPermissions() }.buttonStyle(SettingsActionStyle())
            }.padding(.horizontal,4)
        }
    }
    private func permissionHeading(_ title:String,symbol:String,allowed:Bool,status:String)->some View {
        HStack(spacing:12) {
            Image(systemName:symbol).font(.system(size:20,weight:.medium)).foregroundStyle(.blue)
                .frame(width:44,height:44).background(.blue.opacity(0.06),in:RoundedRectangle(cornerRadius:13))
            Text(title).font(.system(size:15,weight:.semibold))
            Spacer()
            Label(status,systemImage:allowed ? "checkmark.circle.fill":"circle.dashed")
                .font(.system(size:11,weight:.medium)).foregroundStyle(allowed ? Color(red:0.15,green:0.53,blue:0.43):.secondary)
        }
    }
    private func refreshPermissions() {
        screenPermission = CapturePermissions.screen; microphonePermission = CapturePermissions.microphone
    }
    private func openPermissionSettings(microphone:Bool) {
        CapturePermissions.openSettings(microphone:microphone)
        // Keep the draft sheet alive, but let the user interact with the system pane.
        model.hideOverlay()
    }
    private var models: some View {
        Group {
            SettingsCard(title:"Ask Recall",symbol:"sparkles") {
                ProfileEditor(profile:$draft.chat,key:$chatKey,isSpeech:false)
                if !draft.chat.isBuiltin {
                    Button(connecting ? "Connecting…":"Test connection & list models") { testModels() }.disabled(connecting).buttonStyle(SettingsActionStyle())
                    if !detectedModels.isEmpty { Picker("Available models",selection:$draft.chat.model) { Text(draft.chat.model).tag(draft.chat.model); ForEach(detectedModels.filter{$0 != draft.chat.model},id:\.self) { Text($0).tag($0) } } }
                }
                Text(draft.chat.isLocal ? "Local mode keeps your memory text on this computer.":"Matching screen text and transcripts are sent to your provider when you ask. Screenshots stay on this Mac.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            SettingsCard(title:"Meeting transcription",symbol:"text.bubble") {
                SettingsToggle(title:"Transcribe recorded audio",detail:"Turn conversations into searchable memories.",value:$draft.transcriptionEnabled)
                if draft.transcriptionEnabled {
                    Divider().opacity(0.5)
                    ProfileEditor(profile:$draft.transcription,key:$speechKey,isSpeech:true)
                    Text(draft.transcription.isLocal ? "Whisper transcribes directly on this Mac.":"Recorded audio segments are sent to this speech provider while transcription is enabled.").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var storage: some View {
        Group {
            SettingsCard {
                HStack {
                    Label("Storage on this Mac",systemImage:"chart.donut").font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if storageLoading { ProgressView().controlSize(.small).frame(width:44,height:44) }
                    else { Button { storageRefresh = UUID() } label: { Image(systemName:"arrow.clockwise").frame(width:44,height:44) }.buttonStyle(.plain).help("Refresh storage usage").accessibilityLabel("Refresh storage usage") }
                }
                if let usage = storageUsage { StorageUsageChart(usage:usage) }
                else if storageLoading { Text("Measuring files on disk…").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:120) }
                if !storageError.isEmpty { Text(storageError).font(.system(size:12)).foregroundStyle(.orange) }
                Divider().opacity(0.5)
                HStack(spacing:16) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Free up space").font(.system(size:13,weight:.medium))
                        Text("Review and clear old memories and recordings.").font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear storage…",systemImage:"sparkles") { cleanupOpen = true }.buttonStyle(SettingsActionStyle())
                }
            }
            StorageOptimizationCard(optimizer:model.storageOptimizer)
            SettingsCard(title:"Memory library",symbol:"externaldrive") {
                SettingsRow(title:"Keep history") { Picker("Keep history",selection:$draft.retentionDays) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0) }.labelsHidden().frame(width:154) }
                Text("Older unstarred memories move to Trash and remain recoverable. Starred memories are always retained.").font(.system(size:11)).foregroundStyle(.secondary)
                Divider().opacity(0.5)
                Text(model.store.root.path).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                HStack { Button("Open data folder") { NSWorkspace.shared.open(model.store.root) }; Button("Export search results") { model.exportMemories() } }.buttonStyle(SettingsActionStyle())
            }
            SettingsCard(title:"Trash",symbol:"trash") {
                Text("Review deleted memories before removing them permanently.").font(.system(size:11)).foregroundStyle(.secondary)
                HStack {
                    Button("View Trash") { model.trash = true; model.showSearch(); dismiss() }.buttonStyle(SettingsActionStyle())
                    Spacer()
                    Button("Empty permanently…",role:.destructive) { confirmEmptyTrash = true }.buttonStyle(SettingsActionStyle())
                }
            }
            Label("API keys are stored securely in macOS Keychain.",systemImage:"key").font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,6)
        }
    }
    private var shortcuts: some View {
        Group {
            SettingsCard(title:"Open Recall from any app",symbol:"command") {
                shortcutRow(.open)
                Divider().opacity(0.5)
                shortcutRow(.alternate)
                Text("Click a shortcut, then press your preferred combination. Esc cancels recording.").font(.system(size:11)).foregroundStyle(.secondary)
                if let issue = shortcutIssue { Text(issue).font(.system(size:11)).foregroundStyle(.orange) }
                HStack(alignment:.top,spacing:9) {
                    Image(systemName:model.shortcutAvailable ? "checkmark.circle.fill":"exclamationmark.circle").foregroundStyle(model.shortcutAvailable ? Color.green:Color.orange)
                    Text(model.shortcutStatus).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.padding(.vertical,6)
                Button("Retry shortcut registration") { NotificationCenter.default.post(name:.recallRetryShortcut,object:nil) }.buttonStyle(SettingsActionStyle())
                Text("Recall must be running in the menu bar. Shortcuts also work when its window is closed.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            SettingsCard(title:"Within Recall",symbol:"keyboard") {
                ForEach([RecallShortcutAction.search,.previous,.next,.back,.settings]) { action in
                    shortcutRow(action)
                    if action != .settings { Divider().opacity(0.5) }
                }
            }
            Button("Restore default shortcuts") { draft.shortcuts = ShortcutConfiguration(); status = "Defaults restored. Save to apply." }.buttonStyle(SettingsActionStyle())
        }
    }
    private var shortcutIssue:String? {
        do { try draft.shortcuts.validate(); return nil } catch { return error.localizedDescription }
    }
    private func shortcutRow(_ action:RecallShortcutAction)->some View {
        SettingsRow(title:action.title) {
            ShortcutRecorder(title:action.title,binding:Binding(get:{draft.shortcuts[action]},set:{draft.shortcuts[action] = $0}),global:action.isGlobal,changed:{ status = "Shortcut updated. Save to apply." }).frame(width:200,height:44)
            if action == .alternate {
                Button { draft.shortcuts.alternate = nil } label: { Image(systemName:"xmark.circle").frame(width:44,height:44) }.buttonStyle(.plain).help("Disable alternate shortcut").accessibilityLabel("Disable alternate shortcut")
            }
        }
    }
    private func save() {
        saving = true
        draft.excludedApps = excluded.split(separator:"\n").map { String($0).trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        Task {
            do { try await model.saveSettings(draft,chatKey:chatKey,speechKey:speechKey) }
            catch {
                status = error.localizedDescription
                if error is CapturePermissionError { model.settingsTab = "permissions"; refreshPermissions() }
            }
            saving = false
        }
    }
    private func testModels() {
        connecting = true; status = "Connecting…"
        Task { do { detectedModels = try await ModelClient.models(profile:draft.chat,key:chatKey); status = "Connected · \(detectedModels.count) models available" } catch { status = error.localizedDescription }; connecting = false }
    }
}

private struct SettingsCard<Content:View>: View {
    var title: String? = nil
    var symbol: String = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let title { Label(title,systemImage:symbol).font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary).padding(.bottom,2) }
            content()
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
            .background(.white,in:RoundedRectangle(cornerRadius:22,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:22,style:.continuous).strokeBorder(Color(red:0.88,green:0.91,blue:0.95).opacity(0.8)))
            .shadow(color:Color(red:0.15,green:0.28,blue:0.45).opacity(0.035),radius:12,y:4)
    }
}
private struct SettingsRow<Content:View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:4) { Text(title).font(.system(size:13,weight:.medium)); if let detail { Text(detail).font(.system(size:11)).foregroundStyle(.secondary) } }
            Spacer(minLength:8)
            content()
        }.frame(minHeight:44)
    }
}
private struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var value: Bool
    var body: some View {
        SettingsRow(title:title,detail:detail) { Toggle(title,isOn:$value).labelsHidden().toggleStyle(.switch).frame(minWidth:44,minHeight:44) }
    }
}
private struct SettingsActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).padding(.horizontal,16).frame(minHeight:44)
            .foregroundStyle(prominent ? Color.white:Color.primary)
            .background(prominent ? Color.accentColor:Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(prominent ? Color.white.opacity(0.15):Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius:14)).opacity(!enabled ? 0.4:configuration.isPressed ? 0.65:1)
    }
}
private struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing:5) { ForEach(Array(keys.enumerated()),id:\.offset) { _,key in Text(key).font(.system(size:12,weight:.medium,design:.monospaced)).padding(.horizontal,9).frame(minWidth:28,minHeight:30).background(.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).strokeBorder(.primary.opacity(0.07))) } }
    }
}

struct ProfileEditor: View {
    @Binding var profile: ModelProfile
    @Binding var key: String
    let isSpeech: Bool
    var providers: [String] { isSpeech ? ["Built-in","Local Whisper","Online compatible"]:["Built-in","Ollama","LM Studio","Online compatible"] }
    var body: some View {
        SettingsRow(title:"Provider") {
            Picker("Provider",selection:$profile.provider) { ForEach(providers,id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:188)
                .onChange(of:profile.provider) { _,value in
                    profile.isLocal = value != "Online compatible"
                    switch value {
                    case "Built-in": profile = isSpeech ? .builtinSpeech:.builtinChat
                    case "Ollama": profile.baseURL = "http://127.0.0.1:11434/v1"; profile.model = "qwen3:8b"
                    case "LM Studio": profile.baseURL = "http://127.0.0.1:1234/v1"; profile.model = ""
                    case "Local Whisper": profile.baseURL = "http://127.0.0.1:8080/v1"; profile.model = "whisper-1"
                    default: profile.baseURL = "https://api.openai.com/v1"; profile.model = isSpeech ? "whisper-1":""
                    }
                }
        }
        if profile.isBuiltin { BuiltinModelCard(id:isSpeech ? "speech":"chat") }
        else {
            VStack(alignment:.leading,spacing:10) {
                field("API base URL") { TextField("https://…",text:$profile.baseURL).textContentType(.URL) }
                field("Model name") { TextField("Model identifier",text:$profile.model) }
                field("API key") { SecureField("Optional for local providers",text:$key) }
            }
        }
    }
    private func field<Field:View>(_ title:String,@ViewBuilder content:()->Field)->some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary); content().textFieldStyle(.plain).padding(.horizontal,12).frame(height:44).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12)).accessibilityLabel(title) }
    }
}

struct BuiltinModelCard: View {
    let id: String
    @ObservedObject private var library = BuiltinModels.shared
    var body: some View {
        if let item = library.catalog.first(where:{$0.id == id}) {
            VStack(alignment:.leading,spacing:13) {
                HStack(alignment:.top,spacing:14) {
                    Image(systemName:id == "chat" ? "sparkles":"waveform").font(.system(size:24)).foregroundStyle(.indigo).frame(width:48,height:48).background(.indigo.opacity(0.09),in:RoundedRectangle(cornerRadius:14))
                    VStack(alignment:.leading,spacing:5) {Text(item.title).font(.headline);Text(item.subtitle).font(.caption).foregroundStyle(.secondary);Text("\(item.sizeLabel) · \(item.license)").font(.caption2).foregroundStyle(.secondary)}
                    Spacer()
                    if library.busy.contains(id) {Button("Pause") {library.cancel(id)}}
                    else if library.installed.contains(id) {Image(systemName:"checkmark.circle.fill").foregroundStyle(.green);Button("Remove") {Task {await library.remove(item)}}.font(.caption)}
                    else {Button("Download") {library.download(item)}.buttonStyle(.borderedProminent)}
                }
                if library.busy.contains(id) {ProgressView(value:library.progress[id] ?? 0).tint(.indigo)}
                Text(library.status[id] ?? "Download once. Recall runs the model automatically, even offline.").font(.caption).foregroundStyle(.secondary)
                Link("Model details & license",destination:item.source).font(.caption2)
            }.padding(16).background(.background,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(.primary.opacity(0.06)))
        } else {Text("Model catalog missing. Install the complete application package.").foregroundStyle(.secondary)}
    }
}
