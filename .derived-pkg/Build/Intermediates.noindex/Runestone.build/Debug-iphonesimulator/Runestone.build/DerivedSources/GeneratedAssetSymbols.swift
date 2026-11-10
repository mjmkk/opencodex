import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
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

@available(iOS 11.0, macOS 10.13, tvOS 11.0, *)
extension ColorResource {

    /// The "theme_comment" asset catalog color resource.
    static let themeComment = ColorResource(name: "theme_comment", bundle: resourceBundle)

    /// The "theme_constant_builtin" asset catalog color resource.
    static let themeConstantBuiltin = ColorResource(name: "theme_constant_builtin", bundle: resourceBundle)

    /// The "theme_constant_character" asset catalog color resource.
    static let themeConstantCharacter = ColorResource(name: "theme_constant_character", bundle: resourceBundle)

    /// The "theme_constructor" asset catalog color resource.
    static let themeConstructor = ColorResource(name: "theme_constructor", bundle: resourceBundle)

    /// The "theme_current_line" asset catalog color resource.
    static let themeCurrentLine = ColorResource(name: "theme_current_line", bundle: resourceBundle)

    /// The "theme_foreground" asset catalog color resource.
    static let themeForeground = ColorResource(name: "theme_foreground", bundle: resourceBundle)

    /// The "theme_function" asset catalog color resource.
    static let themeFunction = ColorResource(name: "theme_function", bundle: resourceBundle)

    /// The "theme_gutter_background" asset catalog color resource.
    static let themeGutterBackground = ColorResource(name: "theme_gutter_background", bundle: resourceBundle)

    /// The "theme_gutter_hairline" asset catalog color resource.
    static let themeGutterHairline = ColorResource(name: "theme_gutter_hairline", bundle: resourceBundle)

    /// The "theme_invisible_characters" asset catalog color resource.
    static let themeInvisibleCharacters = ColorResource(name: "theme_invisible_characters", bundle: resourceBundle)

    /// The "theme_keyword" asset catalog color resource.
    static let themeKeyword = ColorResource(name: "theme_keyword", bundle: resourceBundle)

    /// The "theme_line_number" asset catalog color resource.
    static let themeLineNumber = ColorResource(name: "theme_line_number", bundle: resourceBundle)

    /// The "theme_line_number_current_line" asset catalog color resource.
    static let themeLineNumberCurrentLine = ColorResource(name: "theme_line_number_current_line", bundle: resourceBundle)

    /// The "theme_marked_text" asset catalog color resource.
    static let themeMarkedText = ColorResource(name: "theme_marked_text", bundle: resourceBundle)

    /// The "theme_number" asset catalog color resource.
    static let themeNumber = ColorResource(name: "theme_number", bundle: resourceBundle)

    /// The "theme_operator" asset catalog color resource.
    static let themeOperator = ColorResource(name: "theme_operator", bundle: resourceBundle)

    /// The "theme_page_guide_background" asset catalog color resource.
    static let themePageGuideBackground = ColorResource(name: "theme_page_guide_background", bundle: resourceBundle)

    /// The "theme_page_guide_hairline" asset catalog color resource.
    static let themePageGuideHairline = ColorResource(name: "theme_page_guide_hairline", bundle: resourceBundle)

    /// The "theme_property" asset catalog color resource.
    static let themeProperty = ColorResource(name: "theme_property", bundle: resourceBundle)

    /// The "theme_punctuation" asset catalog color resource.
    static let themePunctuation = ColorResource(name: "theme_punctuation", bundle: resourceBundle)

    /// The "theme_search_match_found" asset catalog color resource.
    static let themeSearchMatchFound = ColorResource(name: "theme_search_match_found", bundle: resourceBundle)

    /// The "theme_search_match_highlighted" asset catalog color resource.
    static let themeSearchMatchHighlighted = ColorResource(name: "theme_search_match_highlighted", bundle: resourceBundle)

    /// The "theme_selection" asset catalog color resource.
    static let themeSelection = ColorResource(name: "theme_selection", bundle: resourceBundle)

    /// The "theme_string" asset catalog color resource.
    static let themeString = ColorResource(name: "theme_string", bundle: resourceBundle)

    /// The "theme_type" asset catalog color resource.
    static let themeType = ColorResource(name: "theme_type", bundle: resourceBundle)

    /// The "theme_variable_builtin" asset catalog color resource.
    static let themeVariableBuiltin = ColorResource(name: "theme_variable_builtin", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 11.0, macOS 10.7, tvOS 11.0, *)
extension ImageResource {

}

// MARK: - Backwards Deployment Support -

/// A color resource.
struct ColorResource: Swift.Hashable, Swift.Sendable {

    /// An asset catalog color resource name.
    fileprivate let name: Swift.String

    /// An asset catalog color resource bundle.
    fileprivate let bundle: Foundation.Bundle

    /// Initialize a `ColorResource` with `name` and `bundle`.
    init(name: Swift.String, bundle: Foundation.Bundle) {
        self.name = name
        self.bundle = bundle
    }

}

/// An image resource.
struct ImageResource: Swift.Hashable, Swift.Sendable {

    /// An asset catalog image resource name.
    fileprivate let name: Swift.String

    /// An asset catalog image resource bundle.
    fileprivate let bundle: Foundation.Bundle

    /// Initialize an `ImageResource` with `name` and `bundle`.
    init(name: Swift.String, bundle: Foundation.Bundle) {
        self.name = name
        self.bundle = bundle
    }

}

#if canImport(AppKit)
@available(macOS 10.13, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    /// Initialize a `NSColor` with a color resource.
    convenience init(resource: ColorResource) {
        self.init(named: NSColor.Name(resource.name), bundle: resource.bundle)!
    }

}

protocol _ACResourceInitProtocol {}
extension AppKit.NSImage: _ACResourceInitProtocol {}

@available(macOS 10.7, *)
@available(macCatalyst, unavailable)
extension _ACResourceInitProtocol {

    /// Initialize a `NSImage` with an image resource.
    init(resource: ImageResource) {
        self = resource.bundle.image(forResource: NSImage.Name(resource.name))! as! Self
    }

}
#endif

#if canImport(UIKit)
@available(iOS 11.0, tvOS 11.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    /// Initialize a `UIColor` with a color resource.
    convenience init(resource: ColorResource) {
#if !os(watchOS)
        self.init(named: resource.name, in: resource.bundle, compatibleWith: nil)!
#else
        self.init()
#endif
    }

}

@available(iOS 11.0, tvOS 11.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// Initialize a `UIImage` with an image resource.
    convenience init(resource: ImageResource) {
#if !os(watchOS)
        self.init(named: resource.name, in: resource.bundle, compatibleWith: nil)!
#else
        self.init()
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
extension SwiftUI.Color {

    /// Initialize a `Color` with a color resource.
    init(_ resource: ColorResource) {
        self.init(resource.name, bundle: resource.bundle)
    }

}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
extension SwiftUI.Image {

    /// Initialize an `Image` with an image resource.
    init(_ resource: ImageResource) {
        self.init(resource.name, bundle: resource.bundle)
    }

}
#endif