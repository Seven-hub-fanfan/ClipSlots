import AppKit
import QuartzCore
import ClipSlotsKit

struct MascotLampKey: Equatable {
    let side:Int
    let pose:MascotPose
    let activity:MascotMotion.Activity
    let appearance:String
    let display:Data
    init(side:Int,pose:MascotPose,activity:MascotMotion.Activity,appearance:String,display:Data) {
        self.side=side;self.activity=activity;self.appearance=appearance;self.display=display
        var geometry=pose;geometry.logoIntensity=0;geometry.blink=0
        self.pose=geometry
    }
}

/// Pixels use one explicit sRGB, premultiplied RGBA representation. The patch
/// is copied into independent storage; CGImage.cropping would retain a full frame.
struct MascotLampPixels {
    let side:Int
    let bytes:[UInt8]
    init?(_ image:CGImage) {
        guard image.width==image.height,image.width<=1024 else { return nil }
        let side=image.width;self.side=side
        var data=[UInt8](repeating:0,count:side*side*4)
        let ok=data.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:side,height:side,
                bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image,in:CGRect(x:0,y:0,width:side,height:side));return true
        }
        guard ok else { return nil };bytes=data
    }
    func patch(_ rect:CGRect) -> CGImage? {
        let x=Int(rect.minX),y=Int(rect.minY),w=Int(rect.width),h=Int(rect.height)
        guard w>0,h>0,x>=0,y>=0,x+w<=side,y+h<=side else { return nil }
        var data=[UInt8]();data.reserveCapacity(w*h*4)
        for row in y..<y+h {
            data.append(contentsOf:bytes[(row*side+x)*4..<(row*side+x+w)*4])
        }
        guard let provider=CGDataProvider(data:Data(data) as CFData) else { return nil }
        return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,
            shouldInterpolate:false,intent:.defaultIntent)
    }
    func differenceRect(_ other:Self) -> CGRect? {
        guard side==other.side else { return nil }
        var minX=side,minY=side,maxX = -1,maxY = -1
        for pixel in 0..<side*side {
            let offset=pixel*4
            if (0..<4).contains(where:{ bytes[offset+$0] != other.bytes[offset+$0] }) {
                minX=min(minX,pixel%side);maxX=max(maxX,pixel%side)
                minY=min(minY,pixel/side);maxY=max(maxY,pixel/side)
            }
        }
        guard maxX>=minX else { return nil }
        return CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1)
    }
    func matchesOutsideAndOpaque(_ reference:Self,rect:CGRect) -> Bool {
        guard side==reference.side else { return false }
        let x0=Int(rect.minX),x1=Int(rect.maxX),y0=Int(rect.minY),y1=Int(rect.maxY)
        for y in 0..<side { for x in 0..<side {
            let i=(y*side+x)*4
            if x>=x0,x<x1,y>=y0,y<y1 {
                if bytes[i+3] != 255 || reference.bytes[i+3] != 255 { return false }
            } else {
                for c in 0..<4 where bytes[i+c] != reference.bytes[i+c] { return false }
            }
        }}
        return true
    }
    func matchesROI(_ reference:Self,rect:CGRect) -> Bool {
        guard side==reference.side else { return false }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for i in (y*side+Int(rect.minX))*4..<(y*side+Int(rect.maxX))*4 {
                if bytes[i] != reference.bytes[i] { return false }
            }
        }
        return true
    }
}

/// Build order: low/high ROI, full blink trajectory at both light endpoints,
/// then 49 unique breathing images, repeated endpoints and a second full sweep.
/// Requests are issued individually through the display's bounded scheduler.
@MainActor
final class HeaderMascotLampAtlas {
    private(set) var key:MascotLampKey?
    private(set) var epoch:UInt64=0
    private(set) var nextIndex=0
    private(set) var ready=false
    private(set) var rejection:String?
    private(set) var rect=CGRect.zero
    private(set) var frames:[CGImage]=[]
    private var low:MascotLampPixels?
    private var high:MascotLampPixels?
    private var referenceImage:CGImage?
    private(set) var base:NSBitmapImageRep?
    var byteCost:Int { frames.reduce(0) { $0+$1.bytesPerRow*$1.height } }
    var buildCount:Int { 124 }
    func reset(_ newKey:MascotLampKey?) {
        guard key != newKey else { return }
        clear();key=newKey
    }
    func clear() {
        epoch &+= 1;key=nil;nextIndex=0;ready=false;rejection=nil
        low=nil;high=nil;referenceImage=nil;base=nil;frames=[];rect = .zero
    }
    func pose(for index:Int) -> MascotPose? {
        guard let key,!ready,rejection==nil,index<buildCount else { return nil }
        var pose=key.pose
        if index==0 { pose.logoIntensity=0.18 }
        else if index==1 { pose.logoIntensity=1 }
        else if index<24 {
            pose.blink=Double((index-2)%11)/10
            pose.logoIntensity=index<13 ? 0.18 : 1
        } else if index<73 {
            pose.logoIntensity=Self.brightness(index:index-24)
        } else if index<75 { pose.logoIntensity=index==73 ? 0.18 : 1 }
        else { pose.logoIntensity=Self.brightness(index:index-75) }
        return pose
    }
    static func brightness(index:Int) -> Double {
        0.18+0.82*(1-cos(Double(index)*2 * .pi/96))/2
    }
    static func frameIndex(timeMS:Double) -> Int {
        let interval=Int(floor(timeMS.truncatingRemainder(dividingBy:3200)/3200*96))
        return interval<=48 ? interval : 96-interval
    }
    /// Freeze the currently displayed lamp before removing its layer. Retaining
    /// only the low-light base for the next async frame would cause a flash.
    func presentationBitmap(timeMS:Double) -> NSBitmapImageRep? {
        guard ready,let image=base?.cgImage,let pixels=MascotLampPixels(image) else { return nil }
        let patch=frames[Self.frameIndex(timeMS:timeMS)]
        guard let source=patch.dataProvider?.data else { return nil }
        let patchBytes=source as Data
        var bytes=pixels.bytes
        let x=Int(rect.minX),y=Int(rect.minY),w=Int(rect.width),h=Int(rect.height)
        for row in 0..<h {
            let start=((y+row)*pixels.side+x)*4
            bytes.replaceSubrange(start..<start+w*4,with:patchBytes[row*w*4..<(row+1)*w*4])
        }
        guard let provider=CGDataProvider(data:Data(bytes) as CFData),
              let combined=CGImage(width:pixels.side,height:pixels.side,bitsPerComponent:8,
                bitsPerPixel:32,bytesPerRow:pixels.side*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,
                shouldInterpolate:false,intent:.defaultIntent) else { return nil }
        return NSBitmapImageRep(cgImage:combined)
    }
    private func reject(_ reason:String) {
        rejection=reason;low=nil;high=nil;referenceImage=nil;base=nil;frames=[]
    }
    func accept(index:Int,frame:MascotRenderedFrame,limit:Int) {
        guard index==nextIndex,key != nil,!ready,rejection==nil else { return }
        guard frame.geometryInsideFrustum,frame.facialSurfaceValid,
              let rep=frame.bitmap,let image=rep.cgImage,let pixels=MascotLampPixels(image) else {
            reject("invalid raster or geometry");return
        }
        if index==0 { low=pixels;referenceImage=image }
        else if index==1 {
            guard let low,let roi=low.differenceRect(pixels),
                  roi.width*roi.height*4*49<=Double(limit),
                  pixels.matchesOutsideAndOpaque(low,rect:roi) else {
                reject("non-opaque or over-budget lamp region");return
            }
            rect=roi;high=pixels
        } else if index<24 {
            guard let reference=index<13 ? low : high,
                  pixels.matchesROI(reference,rect:rect) else {
                reject("blink changes lamp pixels");return
            }
        } else {
            guard let low,pixels.matchesOutsideAndOpaque(low,rect:rect),
                  let patch=pixels.patch(rect) else {
                reject("nonlocal or transparent brightness change");return
            }
            if index<73 { frames.append(patch) }
            else if index==73 {
                guard pixels.bytes==low.bytes else { reject("unstable low endpoint");return }
            } else if index==74 {
                guard let high,pixels.bytes==high.bytes else { reject("unstable high endpoint");return }
            } else {
                let reference=frames[index-75]
                guard let stored=reference.dataProvider?.data,
                      let repeated=patch.dataProvider?.data,
                      (stored as Data)==(repeated as Data) else {
                    reject("unstable repeated lamp frame");return
                }
            }
            if index==buildCount-1 {
                // The standard base frame remains one full raster, just as in
                // the original renderer; only lamp patches form the new cache.
                if let referenceImage { base=NSBitmapImageRep(cgImage:referenceImage) }
                ready=frames.count==49 && base != nil
                self.low=nil;self.high=nil;self.referenceImage=nil
            }
        }
        nextIndex+=1
    }
}

@MainActor
final class HeaderMascotLampPlayer {
    let layer=CALayer()
    private var playingKey:MascotLampKey?
    var isPlaying:Bool { playingKey != nil }
    init() {
        layer.isHidden=true;layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest;layer.minificationFilter = .nearest
    }
    func stop() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.removeAllAnimations();layer.contents=nil;layer.isHidden=true;playingKey=nil
        CATransaction.commit()
    }
    func play(_ atlas:HeaderMascotLampAtlas,in bounds:CGRect,scale:CGFloat,timeMS:Double) {
        guard atlas.ready,let key=atlas.key else { stop();return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.contentsScale=scale
        layer.frame=CGRect(x:atlas.rect.minX/CGFloat(key.side)*bounds.width,
            y:atlas.rect.minY/CGFloat(key.side)*bounds.height,
            width:atlas.rect.width/CGFloat(key.side)*bounds.width,
            height:atlas.rect.height/CGFloat(key.side)*bounds.height)
        layer.isHidden=false
        if playingKey != key {
            let order=(0...96).map { $0<=48 ? $0 : 96-$0 }
            let animation=CAKeyframeAnimation(keyPath:"contents")
            animation.values=order.map { atlas.frames[$0] }
            animation.keyTimes=(0...96).map { NSNumber(value:Double($0)/96) }
            animation.duration=3.2;animation.repeatCount = .infinity
            animation.calculationMode = .discrete
            animation.timingFunction=CAMediaTimingFunction(name:.linear)
            animation.beginTime=layer.convertTime(CACurrentMediaTime(),from:nil)
            animation.timeOffset=timeMS.truncatingRemainder(dividingBy:3200)/1000
            layer.contents=atlas.frames[0];layer.add(animation,forKey:"mascot.lamp")
            playingKey=key
        }
        CATransaction.commit()
    }
    func brightness(at timeMS:Double) -> Double {
        HeaderMascotLampAtlas.brightness(index:HeaderMascotLampAtlas.frameIndex(timeMS:timeMS))
    }
}
