import Foundation
import CoreGraphics

enum ImagePixelComparison {
    static func psnr(_ a:CGImage,_ b:CGImage)->Double {
        guard a.width == b.width,a.height == b.height else { return 0 }
        let width = min(960,a.width),height = max(1,a.height*width/a.width)
        func pixels(_ image:CGImage)->[UInt8]? {
            var data = [UInt8](repeating:0,count:width*height*4)
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .high;context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
            }
            return ok ? data:nil
        }
        guard let x = pixels(a),let y = pixels(b) else { return 0 }
        var sum = 0.0
        for i in stride(from:0,to:x.count,by:4) { for c in 0..<3 { let delta = Double(x[i+c])-Double(y[i+c]);sum += delta*delta } }
        let mse = sum/Double(width*height*3)
        return mse == 0 ? .infinity:10*log10(255*255/mse)
    }
}

