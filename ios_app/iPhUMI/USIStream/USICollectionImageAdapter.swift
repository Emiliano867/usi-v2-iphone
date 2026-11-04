import Foundation

/// Converts the existing encoder's packed output without rewriting depth or confidence.
enum USICollectionImageAdapter {
    static func make(metadata m: [String: Any], payload: Data) throws -> USICameraImage {
        guard let intrinsics=m["intrinsics_row_major"] as? [Double], intrinsics.count==9,
              let scaled=m["rgb_intrinsics_row_major"] as? [Double], scaled.count==9,
              let source=m["source_image_size"] as? [Int], source.count==2,
              let rgb=m["rgb"] as? [String:Any], rgb["encoding"] as? String=="jpeg",
              let width=rgb["width"] as? Int, let height=rgb["height"] as? Int,
              let length=rgb["length"] as? Int, length>0, length<=payload.count,
              width>0,height>0,source.allSatisfy({$0>0}),
              intrinsics.allSatisfy(\.isFinite),scaled.allSatisfy(\.isFinite) else {
            throw USICollectionError.invalid("malformed encoder output")
        }
        var offset=length
        func plane(_ key: String, encoding: String, bytesPerPixel: Int) throws -> USICameraPlane? {
            guard let descriptor=m[key] as? [String:Any] else { return nil }
            guard descriptor["encoding"] as? String==encoding,
                  let w=descriptor["width"] as? Int, let h=descriptor["height"] as? Int,
                  let size=descriptor["length"] as? Int, w>0,h>0,w<=8192,h<=8192,
                  size==w*h*bytesPerPixel,size<=payload.count-offset else {
                throw USICollectionError.invalid("malformed encoder plane")
            }
            let bytes=payload.subdata(in:offset..<(offset+size));offset+=size
            return USICameraPlane(width:w,height:h,bytes:bytes)
        }
        let depth=try plane("depth",encoding:"float32_le_m",bytesPerPixel:4)
        let confidence=try plane("confidence",encoding:"uint8",bytesPerPixel:1)
        guard offset==payload.count, confidence==nil ||
                (depth != nil && confidence!.width==depth!.width && confidence!.height==depth!.height) else {
            throw USICollectionError.invalid("mismatched encoder planes")
        }
        return USICameraImage(intrinsics:intrinsics,sourceSize:source,rgbIntrinsics:scaled,
            rgbWidth:width,rgbHeight:height,jpeg:payload.subdata(in:0..<length),depth:depth,
            confidence:confidence,thermalState:m["thermal_state"] as? String ?? "unknown")
    }
}
