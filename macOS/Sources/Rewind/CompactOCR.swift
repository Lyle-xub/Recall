import Foundation
import Compression

/// Lossless encoding only; coordinates and text round-trip bit for bit through
/// their existing Codable representation. Bound allocations for damaged input.
enum CompactOCR {
    static func pack(_ data:Data)throws->Data {
        guard data.count <= 16*1024*1024 else {throw RewindError.message("Text index is too large.")}
        let compressed=try (data as NSData).compressed(using:.lzfse) as Data
        var output=Data();var size=UInt32(data.count).littleEndian
        withUnsafeBytes(of:&size) {output.append(contentsOf:$0)}
        output.append(compressed);return output
    }
    static func unpack(_ data:Data)throws->Data {
        guard data.count > 4 else {throw RewindError.message("Incomplete text index.")}
        let size=data.prefix(4).enumerated().reduce(0) {$0 | Int($1.element) << ($1.offset*8)}
        guard size > 0,size <= 16*1024*1024 else {throw RewindError.message("Invalid text index size.")}
        var output=Data(count:size)
        let count=output.withUnsafeMutableBytes { destination in data.dropFirst(4).withUnsafeBytes {source in
            compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,size,source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
        } }
        guard count==size else {throw RewindError.message("Text index could not be decoded.")}
        return output
    }
    static func payload(_ json:Data)throws->String {
        let value=try JSONDecoder().decode(SharedOCR.self,from:json)
        var binary=Data()
        func integer<T:FixedWidthInteger>(_ value:T) {var bits=value.littleEndian;withUnsafeBytes(of:&bits){binary.append(contentsOf:$0)}}
        for regions in [value.regions,value.meetingRegions] {
            integer(UInt32(regions.count))
            for region in regions {
                let text=Data(region.text.utf8);integer(UInt32(text.count));binary.append(text)
                for coordinate in [region.x,region.y,region.width,region.height] {integer(coordinate.bitPattern)}
            }
        }
        let encoded="regions2:"+(try pack(binary)).base64EncodedString()
        return encoded.utf8.count < json.count ? encoded:String(decoding:json,as:UTF8.self)
    }
    static func payload(_ value:String)throws->SharedOCR {
        if value.hasPrefix("regions2:") {
            guard let packed=Data(base64Encoded:String(value.dropFirst(9))) else {throw RewindError.message("Invalid text regions.")}
            let data=try unpack(packed);var offset=0
            func integer<T:FixedWidthInteger>(_ type:T.Type)throws->T {
                guard offset+MemoryLayout<T>.size<=data.count else {throw RewindError.message("Incomplete text regions.")}
                let value=data[offset..<offset+MemoryLayout<T>.size].enumerated().reduce(T.zero) {$0 | T($1.element) << ($1.offset*8)}
                offset += MemoryLayout<T>.size;return value
            }
            func regions()throws->[TextRegion] {
                let count=Int(try integer(UInt32.self))
                guard count<=100_000 else {throw RewindError.message("Invalid text region count.")}
                return try (0..<count).map {index in
                    let length=Int(try integer(UInt32.self))
                    guard offset+length<=data.count,let text=String(data:data[offset..<offset+length],encoding:.utf8) else {throw RewindError.message("Invalid text region text.")}
                    offset += length
                    let values=try (0..<4).map {_ in Double(bitPattern:try integer(UInt64.self))}
                    return TextRegion(id:String(index),text:text,x:values[0],y:values[1],width:values[2],height:values[3])
                }
            }
            let result=SharedOCR(regions:try regions(),meetingRegions:try regions())
            guard offset==data.count else {throw RewindError.message("Invalid trailing text region data.")}
            return result
        }
        let data:Data
        if value.hasPrefix("lzfse1:") {
            guard let packed=Data(base64Encoded:String(value.dropFirst(7))) else {throw RewindError.message("Invalid text index.")}
            data=try unpack(packed)
        } else {data=Data(value.utf8)}
        return try JSONDecoder().decode(SharedOCR.self,from:data)
    }
    static func regionIDs(_ ids:[String])throws->Data? {
        guard !ids.isEmpty else {return nil}
        if ids.enumerated().allSatisfy({$0.element == "r\($0.offset)"}) {
            var count=UInt32(ids.count).littleEndian
            return Data([2])+withUnsafeBytes(of:&count) {Data($0)}
        }
        if ids.allSatisfy({UUID(uuidString:$0)?.uuidString == $0}) {
            var output=Data([1])
            for id in ids {var bytes=UUID(uuidString:id)!.uuid;withUnsafeBytes(of:&bytes){output.append(contentsOf:$0)}}
            return output
        }
        return Data([0])+(try pack(JSONEncoder().encode(ids)))
    }
    static func regionIDs(_ data:Data?)throws->[String]? {
        guard let data else {return nil}
        guard let kind=data.first else {throw RewindError.message("Invalid text region identifiers.")}
        if kind==2 {
            guard data.count==5 else {throw RewindError.message("Invalid text region count.")}
            let count=data.dropFirst().enumerated().reduce(0) {$0 | Int($1.element) << ($1.offset*8)}
            guard count<=100_000 else {throw RewindError.message("Invalid text region count.")}
            return (0..<count).map {"r\($0)"}
        }
        if kind==0 {return try JSONDecoder().decode([String].self,from:unpack(Data(data.dropFirst())))}
        guard kind==1,(data.count-1)%16==0 else {throw RewindError.message("Invalid text region identifiers.")}
        return stride(from:1,to:data.count,by:16).map {offset in
            let bytes=Array(data[offset..<offset+16])
            return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString
        }
    }
    /// New recognitions use stable IDs scoped to their frame. Existing stored
    /// IDs (including arbitrary client IDs) retain the lossless encodings above.
    static func identified(_ recognition:(String,[TextRegion]))->(String,[TextRegion]) {
        var regions=recognition.1
        for index in regions.indices {regions[index].id="r\(index)"}
        return (recognition.0,regions)
    }
}
