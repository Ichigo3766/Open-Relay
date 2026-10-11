import XCTest
import UIKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class RegressionChecks: XCTestCase {
    func inventedJPEG(_ width: Int, _ height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.9) { context in
            for y in stride(from: 0, to: height, by: 32) { for x in stride(from: 0, to: width, by: 32) {
                UIColor(red: CGFloat((x * 17) % 255) / 255, green: CGFloat((y * 31) % 255) / 255, blue: 0.4, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: y, width: 32, height: 32))
            } }
        }
    }
    func testPickedImagesMatchExistingPipeline() async {
        for (width, height) in [(640, 480), (4000, 3000), (3000, 4000)] {
            let data = inventedJPEG(width, height)
            let expected = FileAttachmentService.makeImageAttachment(data: data, name: "Invented Moon.heic")!
            let actual = await FileAttachmentService.prepareImageAttachment(data: data, name: "Invented Moon.heic")!
            XCTAssertEqual(actual.name, "Invented Moon.jpg")
            XCTAssertEqual(SHA256.hash(data: actual.data), SHA256.hash(data: expected.data))
            XCTAssertNotNil(actual.thumbnail)
            let image = UIImage(data: actual.data)!
            XCTAssertLessThanOrEqual(image.size.width * image.size.height, 4_010_000)
            XCTAssertLessThan(actual.data.count, 5 * 1024 * 1024)
        }
    }
    func testInvalidAndCancelledPick() async {
        let invalid = await FileAttachmentService.prepareImageAttachment(data: Data("invented invalid image".utf8))
        XCTAssertNil(invalid)
        let data = inventedJPEG(640, 480)
        let pending = Task { await FileAttachmentService.prepareImageAttachment(data: data) }
        pending.cancel()
        let attachment = await pending.value
        XCTAssertNil(attachment)
    }
    func testUIActorRemainsAvailableDuringConversion() async {
        let data = inventedJPEG(4000, 3000)
        let start = DispatchTime.now().uptimeNanoseconds
        let pending = Task { await FileAttachmentService.prepareImageAttachment(data: data) }
        var ticks = 0
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(2)); ticks += 1 }
        let heartbeat = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertEqual(ticks, 10)
        let result = await pending.value
        XCTAssertNotNil(result)
        print("SYNTHETIC_MEASUREMENT photo_12MP_UI_heartbeat_10_ticks_ms \(heartbeat)")
    }
    func testOrientedImageMatchesExistingPipeline() async throws {
        let source = CGImageSourceCreateWithData(inventedJPEG(640,480) as CFData,nil)!
        let oriented = NSMutableData()
        let writer = CGImageDestinationCreateWithData(oriented,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImageFromSource(writer,source,0,[kCGImagePropertyOrientation:6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let expected = FileAttachmentService.makeImageAttachment(data:oriented as Data,name:"Invented Moon.jpg")!
        let prepared = await FileAttachmentService.prepareImageAttachment(data:oriented as Data,name:"Invented Moon.jpg")
        let actual = try XCTUnwrap(prepared)
        XCTAssertEqual(SHA256.hash(data:actual.data),SHA256.hash(data:expected.data))
        let size = UIImage(data:actual.data)!.size
        XCTAssertEqual(size.width,480); XCTAssertEqual(size.height,640)
    }
    func testSyntheticPreparedImageOnScreen() async throws {
        let data = inventedJPEG(4000,3000)
        let prepared = await FileAttachmentService.prepareImageAttachment(data:data,name:"Invented Moon.jpg")
        let result = try XCTUnwrap(prepared)
        let controller = UIViewController(); controller.view.backgroundColor = .white
        let title = UILabel(); title.text = "Synthetic 12 MP image preparation"; title.textAlignment = .center
        let detail = UILabel(); detail.text = "Invented Moon.jpg • upload ready"; detail.textAlignment = .center
        let image = UIImageView(image:UIImage(data:result.data)); image.contentMode = .scaleAspectFit
        let stack = UIStackView(arrangedSubviews:[title,detail,image]); stack.axis = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:controller.view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:controller.view.trailingAnchor,constant:-20),stack.centerYAnchor.constraint(equalTo:controller.view.centerYAnchor),image.heightAnchor.constraint(equalToConstant:400)])
        let window = UIWindow(windowScene:UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.frame = UIScreen.main.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for:.seconds(2)); window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:screenshot); attachment.name = "synthetic-prepared-image"; attachment.lifetime = .keepAlways; add(attachment)
        try await Task.sleep(for:.seconds(2))
    }

}
