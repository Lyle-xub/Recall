import AppKit
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let window=NSWindow(contentRect:NSRect(x:100,y:100,width:1100,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
window.title="Recall CLI synthetic capture fixture"
window.backgroundColor = .white
let text=NSTextField(wrappingLabelWithString:"Aurora launch is Tuesday\nRecall native capture validation\nSynthetic data only — no personal content")
text.frame=NSRect(x:50,y:120,width:1000,height:420)
text.font = .systemFont(ofSize:48,weight:.semibold);text.textColor = .black
window.contentView!.addSubview(text)
window.level = .floating;window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
DispatchQueue.main.asyncAfter(deadline:.now()+90) {app.terminate(nil)}
app.run()
