import CoreGraphics

struct IconTint: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    var isNeutral: Bool { max(red,green,blue)-min(red,green,blue) < 0.06 }
}

enum IconColorSampler {
    /// Quantize chromatic pixels by hue, then average the dominant neighborhood.
    /// Transparent padding, white icon tiles and black outlines do not dilute a
    /// colored mark. Truly monochrome icons keep a neutral tint.
    static func sample(_ image:CGImage)->IconTint? {
        let side = 48
        var pixels = [UInt8](repeating:0,count:side*side*4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name:CGColorSpace.sRGB),
                  let context = CGContext(data:bytes.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image,in:CGRect(x:0,y:0,width:side,height:side)); return true
        }
        guard drawn else { return nil }
        var bins = [Double](repeating:0,count:24)
        var chromatic:[(hue:Double,r:Double,g:Double,b:Double,weight:Double)] = []
        var opaque = 0.0, neutral = 0.0, neutralWeight = 0.0
        for i in stride(from:0,to:pixels.count,by:4) {
            let alpha = Double(pixels[i+3])/255
            guard alpha > 0.35 else { continue }
            let r = min(1,Double(pixels[i])/255/alpha),g = min(1,Double(pixels[i+1])/255/alpha),b = min(1,Double(pixels[i+2])/255/alpha)
            let high = max(r,g,b),low = min(r,g,b),delta = high-low
            opaque += alpha
            let grayWeight = alpha*pow(1-high,2)
            neutral += (r+g+b)/3*grayWeight; neutralWeight += grayWeight
            guard high > 0.12,delta/max(high,0.001) > 0.18 else { continue }
            var hue = high == r ? (g-b)/delta:high == g ? (b-r)/delta+2:(r-g)/delta+4
            hue = (hue/6+1).truncatingRemainder(dividingBy:1)
            let weight = alpha*delta
            bins[min(23,Int(hue*24))] += weight
            chromatic.append((hue,r,g,b,weight))
        }
        guard opaque > 0 else { return nil }
        if chromatic.reduce(0.0,{$0+$1.weight}) < opaque*0.015 {
            let gray = min(0.65,max(0.32,neutralWeight > 0 ? neutral/neutralWeight:0.65))
            return IconTint(red:gray,green:gray,blue:gray)
        }
        var peak = 0, peakScore = 0.0
        for index in 0..<24 {
            let neighbors = bins[(index+23)%24] + bins[(index+1)%24]
            let score = neighbors + bins[index]
            if score > peakScore { peak = index; peakScore = score }
        }
        let center = (Double(peak)+0.5)/24
        var total = 0.0,r = 0.0,g = 0.0,b = 0.0
        for pixel in chromatic {
            let distance = abs(pixel.hue-center)
            guard min(distance,1-distance) < 0.085 else { continue }
            total += pixel.weight; r += pixel.r*pixel.weight; g += pixel.g*pixel.weight; b += pixel.b*pixel.weight
        }
        guard total > 0 else { return nil }
        r /= total; g /= total; b /= total
        let brightness = max(r,g,b)
        let adjustment = min(0.86,max(0.50,brightness))/max(0.001,brightness)
        return IconTint(red:r*adjustment,green:g*adjustment,blue:b*adjustment)
    }
}
