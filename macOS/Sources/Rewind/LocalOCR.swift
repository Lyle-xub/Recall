import Foundation
import CoreGraphics

/// The bundled LSTM recognizer is independent of Apple's Vision/E5RT service.
/// It only reads local pixels and writes temporary local TSV, never the network.
enum LocalOCR {
    static var root:URL? {
        var roots = [Bundle.main.resourceURL?.appendingPathComponent("runtimes/ocr")].compactMap{$0}
        #if DEBUG
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        roots.append(project.appendingPathComponent("native-runtimes/macos-arm64/ocr"))
        #endif
        return roots.first { FileManager.default.isExecutableFile(atPath:$0.appendingPathComponent("tesseract").path) && FileManager.default.fileExists(atPath:$0.appendingPathComponent("tessdata/chi_sim.traineddata").path) }
    }
    static func recognize(_ image:CGImage) throws -> (String,[TextRegion]) {
        try Task.checkCancellation()
        guard let root else { throw RewindError.message("The local text-recognition engine is missing. Reinstall Recall to restore it; your screenshots are safe.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("recall-ocr-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temp) }
        let input = temp.appendingPathComponent("source.png"),output = temp.appendingPathComponent("recognized")
        try ScreenArchive.saveSource(image,to:input)
        let process = Process()
        process.qualityOfService = .utility
        process.executableURL = root.appendingPathComponent("tesseract")
        process.arguments = [input.path,output.path,"--tessdata-dir",root.appendingPathComponent("tessdata").path,"-l","chi_sim+eng","--oem","1","--psm","11","-c","tessedit_create_tsv=1","-c","user_defined_dpi=144"]
        var environment = ProcessInfo.processInfo.environment
        environment["OMP_THREAD_LIMIT"] = "2";process.environment = environment
        process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+30,execute:deadline)
        process.waitUntilExit();deadline.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw RewindError.message("Local text recognition will retry. The original screenshot has been kept.") }
        let tsv = try String(contentsOf:output.appendingPathExtension("tsv"),encoding:.utf8)
        let regions = parse(tsv,width:image.width,height:image.height)
        return (regions.map(\.text).joined(separator:"\n"),regions)
    }
    static func parse(_ tsv:String,width:Int,height:Int)->[TextRegion] {
        guard width > 0,height > 0 else { return [] }
        var order:[String] = [],lines:[String:(text:String,box:CGRect)] = [:]
        for row in tsv.split(whereSeparator:\.isNewline) {
            let fields = row.split(separator:"\t",maxSplits:11,omittingEmptySubsequences:false)
            guard fields.count == 12,fields[0] == "5",let x = Double(fields[6]),let y = Double(fields[7]),let w = Double(fields[8]),let h = Double(fields[9]),w > 0,h > 0 else { continue }
            let word = fields[11].trimmingCharacters(in:.whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let key = fields[1...4].joined(separator:"-")
            let box = CGRect(x:x,y:y,width:w,height:h).intersection(CGRect(x:0,y:0,width:width,height:height))
            guard !box.isNull,!box.isEmpty else { continue }
            if var line = lines[key] {
                let separator = line.text.last.map(isCJK) == true && word.first.map(isCJK) == true ? "":" "
                line.text += separator+word;line.box = line.box.union(box);lines[key] = line
            } else { order.append(key);lines[key] = (word,box) }
        }
        return order.compactMap { key in
            guard let line = lines[key] else { return nil }
            return TextRegion(text:line.text,x:line.box.minX/Double(width),y:line.box.minY/Double(height),width:line.box.width/Double(width),height:line.box.height/Double(height))
        }
    }
    private static func isCJK(_ character:Character)->Bool {
        character.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value) }
    }
}
