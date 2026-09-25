import SwiftUI

struct RecognitionStatusView:View {
    @ObservedObject var model:AppModel
    @ObservedObject private var activity:RecognitionActivity
    let frame:MemoryFrame
    @StateObject private var presentation = RecognitionStatusPresentation()
    init(model:AppModel,frame:MemoryFrame) { self.model = model;self.frame = frame;activity = model.recognitionActivity }
    private var current:RecognitionStatusSnapshot {
        .current(frame:frame,video:model.player != nil,meeting:model.meetingView,activity:activity,recording:model.recordingDetail,speechEnabled:model.settings.transcriptionEnabled)
    }
    var body:some View {
        let source = current
        let shown = presentation.snapshot.flatMap { $0.contextID == source.contextID ? $0:nil } ?? source
        HStack(spacing:6) {
            if let text = shown.text { capsule(text,speech:false) }
            if let speech = shown.speech { capsule(speech,speech:true) }
        }.font(.system(size:10,weight:.medium)).fixedSize(horizontal:true,vertical:false)
            .accessibilityElement(children:.combine)
            .transaction { $0.animation = nil }
            .onChange(of:source,initial:true) { _,value in presentation.receive(value) }
            .onDisappear { presentation.cancel() }
    }
    private func capsule(_ state:MediaRecognitionState,speech:Bool)->some View {
        let kind = speech ? "Speech":"Text"
        let content = speech ? "this recording":"this image"
        let label:String,detail:String,symbol:String,color:Color
        switch state {
        case .checking:
            label = kind+" · checking";detail = "Loading the saved recognition status of \(content).";symbol = "ellipsis";color = .secondary
        case .queued:
            label = kind+" · queued";detail = "This \(speech ? "recording":"image") is waiting for recognition.";symbol = "clock";color = speech ? .indigo:.teal
        case .processing:
            label = speech ? "Transcribing audio":"Recognizing text";detail = "Processing \(content), including saving its result.";symbol = speech ? "waveform":"text.viewfinder";color = speech ? .indigo:.teal
        case .complete:
            label = kind+" · ready";detail = "Recognition of \(content) is complete. Its text can be selected and copied.";symbol = "checkmark.circle.fill";color = Color(red:0.12,green:0.48,blue:0.36)
        case .empty:
            label = speech ? "No speech detected":"No text detected";detail = "Recognition of \(content) finished without \(speech ? "speech":"readable text").";symbol = speech ? "waveform":"text.viewfinder";color = .secondary
        case .noAudio:
            label = "No audio";detail = "This recording has no audio track to transcribe.";symbol = "speaker.slash";color = .secondary
        case .disabled:
            label = "Speech · off";detail = "Transcription is disabled, and this recording has no saved transcript.";symbol = "waveform";color = .secondary
        case .notProcessed:
            label = kind+" · not processed";detail = "No completed recognition result is available for \(content).";symbol = "minus.circle";color = .secondary
        case .awaitingEnd:
            label = "Speech · waiting";detail = "This audio segment will be transcribed once recording finishes.";symbol = "clock";color = .indigo
        case .failed(let reason):
            label = kind+" · needs attention";detail = reason;symbol = "exclamationmark.circle.fill";color = .orange
        }
        return Label(label,systemImage:symbol).foregroundStyle(color)
            .padding(.horizontal,10).padding(.vertical,7)
            .background(color.opacity(0.11),in:Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.13)))
            .help(detail).accessibilityLabel(label+". "+detail)
    }
}
