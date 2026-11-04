import Foundation
import XCTest
@testable import USIWire

final class USICollectionImageAdapterTests: XCTestCase {
    private var metadata: [String: Any] {
        ["intrinsics_row_major": [1.0,0,0,0,1,0,0,0,1], "source_image_size": [4,2],
         "rgb_intrinsics_row_major": [0.5,0,0,0,0.5,0,0,0,1],
         "rgb": ["encoding":"jpeg","width":2,"height":1,"length":3],
         "depth": ["encoding":"float32_le_m","width":2,"height":1,"length":8],
         "confidence": ["encoding":"uint8","width":2,"height":1,"length":2], "thermal_state":"nominal"]
    }
    func testRawPlanesAndScaledIntrinsicsArePreserved() throws {
        let depth = Data([0,0,128,63,0,0,192,127]) // 1 m and raw NaN
        let image = try USICollectionImageAdapter.make(metadata: metadata,
            payload: Data("jpg".utf8) + depth + Data([2,0]))
        XCTAssertEqual(image.jpeg, Data("jpg".utf8))
        XCTAssertEqual(image.depth?.bytes, depth)
        XCTAssertEqual(image.confidence?.bytes, Data([2,0]))
        XCTAssertEqual(image.sourceSize, [4,2])
        XCTAssertEqual(image.rgbIntrinsics[0], 0.5)
    }
    func testPartialPayloadAndMismatchedPlanesAreRejected() throws {
        XCTAssertThrowsError(try USICollectionImageAdapter.make(metadata:metadata,payload:Data(repeating:0,count:12)))
        var bad=metadata; bad["confidence"]=["encoding":"uint8","width":1,"height":2,"length":2]
        XCTAssertThrowsError(try USICollectionImageAdapter.make(metadata:bad,payload:Data(repeating:0,count:13)))
    }
}
