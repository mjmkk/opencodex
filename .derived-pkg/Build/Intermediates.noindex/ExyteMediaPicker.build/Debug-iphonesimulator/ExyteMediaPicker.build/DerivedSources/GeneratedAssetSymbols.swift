import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "cameraBG" asset catalog color resource.
    static let cameraBG = DeveloperToolsSupport.ColorResource(name: "cameraBG", bundle: resourceBundle)

    /// The "cameraText" asset catalog color resource.
    static let cameraText = DeveloperToolsSupport.ColorResource(name: "cameraText", bundle: resourceBundle)

    /// The "pickerBG" asset catalog color resource.
    static let pickerBG = DeveloperToolsSupport.ColorResource(name: "pickerBG", bundle: resourceBundle)

    /// The "pickerText" asset catalog color resource.
    static let pickerText = DeveloperToolsSupport.ColorResource(name: "pickerText", bundle: resourceBundle)

    /// The "selection" asset catalog color resource.
    static let selection = DeveloperToolsSupport.ColorResource(name: "selection", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "FlashOff" asset catalog image resource.
    static let flashOff = DeveloperToolsSupport.ImageResource(name: "FlashOff", bundle: resourceBundle)

    /// The "FlashOn" asset catalog image resource.
    static let flashOn = DeveloperToolsSupport.ImageResource(name: "FlashOn", bundle: resourceBundle)

    /// The "FlipCamera" asset catalog image resource.
    static let flipCamera = DeveloperToolsSupport.ImageResource(name: "FlipCamera", bundle: resourceBundle)

}

