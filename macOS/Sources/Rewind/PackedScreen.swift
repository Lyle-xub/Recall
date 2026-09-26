import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

struct ScreenTile:Sendable { let path:String;let data:Data }
struct PackedScreen:Codable,Sendable {
    struct Tile:Codable,Sendable {let path:String;let x:Int;let y:Int;let width:Int;let height:Int}
    let version:Int
    let width:Int
    let height:Int
    let tiles:[Tile]
    static let fileExtension = "recallframe"
    private final class Encoded:NSObject {let tile:ScreenTile;init(_ tile:ScreenTile){self.tile=tile}}
    private final class Decoded:NSObject {let image:CGImage;init(_ image:CGImage){self.image=image}}
    private static let encodedCache:NSCache<NSString,Encoded> = {let c=NSCache<NSString,Encoded>();c.countLimit=1024;c.totalCostLimit=32*1024*1024;return c}()
    private static let decodedCache:NSCache<NSString,Decoded> = {let c=NSCache<NSString,Decoded>();c.countLimit=128;c.totalCostLimit=96*1024*1024;return c}()
    static func encode(_ image:CGImage) throws -> ScreenArchive {
        guard image.width > 0,image.height > 0,image.width <= 16000,image.height <= 16000,image.width*image.height <= 40_000_000 else {return try ScreenArchive.make(image)}
        // Normalize/decode once. Drawing a crop of an ImageIO-backed image for
        // every tile can repeat decoding and color conversion of its source.
        guard let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw RewindError.message("Could not archive this screenshot.")}
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let pixels=context.data,let normalizedImage=context.makeImage() else {throw RewindError.message("Could not prepare image tiles.")}
        var entries:[Tile]=[],payload:[String:ScreenTile]=[:]
        let side=384
        for y in stride(from:0,to:image.height,by:side) {
            try Task.checkCancellation()
            for x in stride(from:0,to:image.width,by:side) {
                let width=min(side,image.width-x),height=min(side,image.height-y)
                let tile = try autoreleasepool { () throws -> ScreenTile in
                    guard let normalized=normalizedImage.cropping(to:CGRect(x:x,y:y,width:width,height:height)) else {throw RewindError.message("Could not prepare image tiles.")}
                    var bytes=Data(count:width*height*4)
                    bytes.withUnsafeMutableBytes { buffer in
                        for row in 0..<height {
                            memcpy(buffer.baseAddress!.advanced(by:row*width*4),pixels.advanced(by:(y+row)*image.width*4+x*4),width*4)
                        }
                    }
                    let key="t1-q\(ScreenArchive.compressionQuality)-\(width)-\(height)-"+ImageArchive.digest(bytes)
                    if let cached=encodedCache.object(forKey:key as NSString) {return cached.tile}
                    let png=try ScreenArchive.encode(normalized,type:.png)
                    // Starting a video codec for a tiny flat/text tile costs
                    // more than the few KB it can save. Keep these lossless;
                    // photos and other large tiles still use the compact codec.
                    let tryHEIC=png.count > 16*1024 && bytes.withUnsafeBytes { buffer in
                        let raw=buffer.bindMemory(to:UInt8.self)
                        return stride(from:3,to:raw.count,by:4).allSatisfy {raw[$0]==255}
                    }
                    let heic=tryHEIC ? try? ScreenArchive.encode(normalized,type:.heic,quality:ScreenArchive.compressionQuality):nil
                    let useHEIC=heic.map { Double($0.count)*1.12 < Double(png.count) } ?? false
                    let encoded=useHEIC ? heic!:png,ext=useHEIC ? "heic":"png"
                    let result=ScreenTile(path:"frames/tiles/t1-"+ImageArchive.digest(encoded)+"."+ext,data:encoded)
                    encodedCache.setObject(Encoded(result),forKey:key as NSString,cost:encoded.count)
                    return result
                }
                payload[tile.path]=tile
                entries.append(Tile(path:tile.path,x:x,y:y,width:width,height:height))
            }
        }
        let manifest=PackedScreen(version:1,width:image.width,height:image.height,tiles:entries)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return ScreenArchive(data:try encoder.encode(manifest),fileExtension:fileExtension,tiles:payload.values.sorted {$0.path < $1.path})
    }
    static func manifest(_ data:Data) throws -> PackedScreen {
        guard data.count <= 2_000_000 else {throw RewindError.message("Invalid screenshot manifest.")}
        let value=try JSONDecoder().decode(PackedScreen.self,from:data)
        guard value.version==1,value.width>0,value.height>0,value.width<=16000,value.height<=16000,value.width*value.height<=40_000_000,
              value.tiles.count == ((value.width+383)/384)*((value.height+383)/384) else {throw RewindError.message("Invalid screenshot dimensions.")}
        var cells=Set<String>()
        for tile in value.tiles {
            let name=URL(fileURLWithPath:tile.path).lastPathComponent
            let hash=String(name.dropFirst(3).split(separator:".").first ?? "")
            guard tile.path == "frames/tiles/"+name,name.hasPrefix("t1-"),["png","heic"].contains(URL(fileURLWithPath:name).pathExtension),
                  hash.count==64,hash.allSatisfy({$0.isHexDigit}),tile.x>=0,tile.y>=0,tile.x%384==0,tile.y%384==0,
                  tile.width==min(384,value.width-tile.x),tile.height==min(384,value.height-tile.y),tile.width>0,tile.height>0,
                  cells.insert("\(tile.x)-\(tile.y)").inserted else {throw RewindError.message("Invalid screenshot tile.")}
        }
        return value
    }
    static func load(_ url:URL,maxPixels:Int? = nil,useCache:Bool = true) throws -> CGImage {
        let value=try manifest(Data(contentsOf:url)),root=url.deletingLastPathComponent().deletingLastPathComponent()
        let packs = TilePackReader.cached(root:root)
        let scale=maxPixels.map {min(1,Double($0)/Double(max(value.width,value.height)))} ?? 1
        let width=max(1,Int(Double(value.width)*scale)),height=max(1,Int(Double(value.height)*scale))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw RewindError.message("Could not display the screenshot.")}
        context.interpolationQuality = .high
        for tile in value.tiles {
            try Task.checkCancellation()
            let file=try CleanupFiles.ownedURL(tile.path,root:root),key=file.path as NSString
            let image:CGImage
            if useCache,let cached=decodedCache.object(forKey:key) {image=cached.image}
            else {
                let reader:CGImageSource?
                if FileManager.default.fileExists(atPath:file.path),let legacy=CGImageSourceCreateWithURL(file as CFURL,nil) {reader=legacy}
                else if let data = try packs?.read(tile.path) {reader=CGImageSourceCreateWithData(data as CFData,nil)}
                else {reader=nil}
                guard let reader,let decoded=CGImageSourceCreateImageAtIndex(reader,0,nil),decoded.width==tile.width,decoded.height==tile.height else {throw RewindError.message("A screenshot tile could not be read.")}
                image=decoded;if useCache {decodedCache.setObject(Decoded(image),forKey:key,cost:image.bytesPerRow*image.height)}
            }
            let x0=Int(Double(tile.x)*scale),x1=Int(Double(tile.x+tile.width)*scale)
            let y0=Int(Double(tile.y)*scale),y1=Int(Double(tile.y+tile.height)*scale)
            context.draw(image,in:CGRect(x:x0,y:height-y1,width:x1-x0,height:y1-y0))
        }
        guard let image=context.makeImage() else {throw RewindError.message("Could not assemble the screenshot.")}
        return image
    }
}

enum StoredImage {
    static func load(_ url:URL,maxPixels:Int? = nil)->CGImage? {
        if url.pathExtension == PackedScreen.fileExtension {return try? PackedScreen.load(url,maxPixels:maxPixels)}
        guard let reader=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else {return nil}
        if let maxPixels {
            return CGImageSourceCreateThumbnailAtIndex(reader,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxPixels,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(reader,0,nil)
    }
}
