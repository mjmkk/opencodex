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

    /// The "inputBG" asset catalog color resource.
    static let inputBG = DeveloperToolsSupport.ColorResource(name: "inputBG", bundle: resourceBundle)

    /// The "inputPlaceholderText" asset catalog color resource.
    static let inputPlaceholderText = DeveloperToolsSupport.ColorResource(name: "inputPlaceholderText", bundle: resourceBundle)

    /// The "mainBG" asset catalog color resource.
    static let mainBG = DeveloperToolsSupport.ColorResource(name: "mainBG", bundle: resourceBundle)

    /// The "mainCaptionText" asset catalog color resource.
    static let mainCaptionText = DeveloperToolsSupport.ColorResource(name: "mainCaptionText", bundle: resourceBundle)

    /// The "mainText" asset catalog color resource.
    static let mainText = DeveloperToolsSupport.ColorResource(name: "mainText", bundle: resourceBundle)

    /// The "menuBG" asset catalog color resource.
    static let menuBG = DeveloperToolsSupport.ColorResource(name: "menuBG", bundle: resourceBundle)

    /// The "menuText" asset catalog color resource.
    static let menuText = DeveloperToolsSupport.ColorResource(name: "menuText", bundle: resourceBundle)

    /// The "menuTextDelete" asset catalog color resource.
    static let menuTextDelete = DeveloperToolsSupport.ColorResource(name: "menuTextDelete", bundle: resourceBundle)

    /// The "messageFriendBG" asset catalog color resource.
    static let messageFriendBG = DeveloperToolsSupport.ColorResource(name: "messageFriendBG", bundle: resourceBundle)

    /// The "messageFriendTimeText" asset catalog color resource.
    static let messageFriendTimeText = DeveloperToolsSupport.ColorResource(name: "messageFriendTimeText", bundle: resourceBundle)

    /// The "messageMyBG" asset catalog color resource.
    static let messageMyBG = DeveloperToolsSupport.ColorResource(name: "messageMyBG", bundle: resourceBundle)

    /// The "messageMyTimeText" asset catalog color resource.
    static let messageMyTimeText = DeveloperToolsSupport.ColorResource(name: "messageMyTimeText", bundle: resourceBundle)

    /// The "messageReadStatus" asset catalog color resource.
    static let messageReadStatus = DeveloperToolsSupport.ColorResource(name: "messageReadStatus", bundle: resourceBundle)

    /// The "statusError" asset catalog color resource.
    static let statusError = DeveloperToolsSupport.ColorResource(name: "statusError", bundle: resourceBundle)

    /// The "statusGray" asset catalog color resource.
    static let statusGray = DeveloperToolsSupport.ColorResource(name: "statusGray", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "MuteVideo" asset catalog image resource.
    static let muteVideo = DeveloperToolsSupport.ImageResource(name: "MuteVideo", bundle: resourceBundle)

    /// The "Poweredby_100px-Black_VertText" asset catalog image resource.
    static let poweredby100PxBlackVertText = DeveloperToolsSupport.ImageResource(name: "Poweredby_100px-Black_VertText", bundle: resourceBundle)

    /// The "Poweredby_100px-White_VertText" asset catalog image resource.
    static let poweredby100PxWhiteVertText = DeveloperToolsSupport.ImageResource(name: "Poweredby_100px-White_VertText", bundle: resourceBundle)

    /// The "add" asset catalog image resource.
    static let add = DeveloperToolsSupport.ImageResource(name: "add", bundle: resourceBundle)

    /// The "arrowSend" asset catalog image resource.
    static let arrowSend = DeveloperToolsSupport.ImageResource(name: "arrowSend", bundle: resourceBundle)

    /// The "attach" asset catalog image resource.
    static let attach = DeveloperToolsSupport.ImageResource(name: "attach", bundle: resourceBundle)

    /// The "attachCamera" asset catalog image resource.
    static let attachCamera = DeveloperToolsSupport.ImageResource(name: "attachCamera", bundle: resourceBundle)

    /// The "attachedDocument" asset catalog image resource.
    static let attachedDocument = DeveloperToolsSupport.ImageResource(name: "attachedDocument", bundle: resourceBundle)

    /// The "backArrow" asset catalog image resource.
    static let backArrow = DeveloperToolsSupport.ImageResource(name: "backArrow", bundle: resourceBundle)

    /// The "camera" asset catalog image resource.
    static let camera = DeveloperToolsSupport.ImageResource(name: "camera", bundle: resourceBundle)

    /// The "cancelRecord" asset catalog image resource.
    static let cancelRecord = DeveloperToolsSupport.ImageResource(name: "cancelRecord", bundle: resourceBundle)

    /// The "cancelReply" asset catalog image resource.
    static let cancelReply = DeveloperToolsSupport.ImageResource(name: "cancelReply", bundle: resourceBundle)

    /// The "check" asset catalog image resource.
    static let check = DeveloperToolsSupport.ImageResource(name: "check", bundle: resourceBundle)

    /// The "checkAll" asset catalog image resource.
    static let checkAll = DeveloperToolsSupport.ImageResource(name: "checkAll", bundle: resourceBundle)

    /// The "chevronDown" asset catalog image resource.
    static let chevronDown = DeveloperToolsSupport.ImageResource(name: "chevronDown", bundle: resourceBundle)

    /// The "chevronRight" asset catalog image resource.
    static let chevronRight = DeveloperToolsSupport.ImageResource(name: "chevronRight", bundle: resourceBundle)

    /// The "contact" asset catalog image resource.
    static let contact = DeveloperToolsSupport.ImageResource(name: "contact", bundle: resourceBundle)

    /// The "cross" asset catalog image resource.
    static let cross = DeveloperToolsSupport.ImageResource(name: "cross", bundle: resourceBundle)

    /// The "delete" asset catalog image resource.
    static let delete = DeveloperToolsSupport.ImageResource(name: "delete", bundle: resourceBundle)

    /// The "deleteRecord" asset catalog image resource.
    static let deleteRecord = DeveloperToolsSupport.ImageResource(name: "deleteRecord", bundle: resourceBundle)

    /// The "document" asset catalog image resource.
    static let document = DeveloperToolsSupport.ImageResource(name: "document", bundle: resourceBundle)

    /// The "edit" asset catalog image resource.
    static let edit = DeveloperToolsSupport.ImageResource(name: "edit", bundle: resourceBundle)

    /// The "forward" asset catalog image resource.
    static let forward = DeveloperToolsSupport.ImageResource(name: "forward", bundle: resourceBundle)

    /// The "location" asset catalog image resource.
    static let location = DeveloperToolsSupport.ImageResource(name: "location", bundle: resourceBundle)

    /// The "lockRecord" asset catalog image resource.
    static let lockRecord = DeveloperToolsSupport.ImageResource(name: "lockRecord", bundle: resourceBundle)

    /// The "microphone" asset catalog image resource.
    static let microphone = DeveloperToolsSupport.ImageResource(name: "microphone", bundle: resourceBundle)

    /// The "pauseAudio" asset catalog image resource.
    static let pauseAudio = DeveloperToolsSupport.ImageResource(name: "pauseAudio", bundle: resourceBundle)

    /// The "pauseRecord" asset catalog image resource.
    static let pauseRecord = DeveloperToolsSupport.ImageResource(name: "pauseRecord", bundle: resourceBundle)

    /// The "photo" asset catalog image resource.
    static let photo = DeveloperToolsSupport.ImageResource(name: "photo", bundle: resourceBundle)

    /// The "pickDocument" asset catalog image resource.
    static let pickDocument = DeveloperToolsSupport.ImageResource(name: "pickDocument", bundle: resourceBundle)

    /// The "pickLocation" asset catalog image resource.
    static let pickLocation = DeveloperToolsSupport.ImageResource(name: "pickLocation", bundle: resourceBundle)

    /// The "pickPhoto" asset catalog image resource.
    static let pickPhoto = DeveloperToolsSupport.ImageResource(name: "pickPhoto", bundle: resourceBundle)

    /// The "playAudio" asset catalog image resource.
    static let playAudio = DeveloperToolsSupport.ImageResource(name: "playAudio", bundle: resourceBundle)

    /// The "playRecord" asset catalog image resource.
    static let playRecord = DeveloperToolsSupport.ImageResource(name: "playRecord", bundle: resourceBundle)

    /// The "reply" asset catalog image resource.
    static let reply = DeveloperToolsSupport.ImageResource(name: "reply", bundle: resourceBundle)

    /// The "replyToMessage" asset catalog image resource.
    static let replyToMessage = DeveloperToolsSupport.ImageResource(name: "replyToMessage", bundle: resourceBundle)

    /// The "retry" asset catalog image resource.
    static let retry = DeveloperToolsSupport.ImageResource(name: "retry", bundle: resourceBundle)

    /// The "save" asset catalog image resource.
    static let save = DeveloperToolsSupport.ImageResource(name: "save", bundle: resourceBundle)

    /// The "scrollToBottom" asset catalog image resource.
    static let scrollToBottom = DeveloperToolsSupport.ImageResource(name: "scrollToBottom", bundle: resourceBundle)

    /// The "select" asset catalog image resource.
    static let select = DeveloperToolsSupport.ImageResource(name: "select", bundle: resourceBundle)

    /// The "sendRecord" asset catalog image resource.
    static let sendRecord = DeveloperToolsSupport.ImageResource(name: "sendRecord", bundle: resourceBundle)

    /// The "sticker" asset catalog image resource.
    static let sticker = DeveloperToolsSupport.ImageResource(name: "sticker", bundle: resourceBundle)

    /// The "stopRecord" asset catalog image resource.
    static let stopRecord = DeveloperToolsSupport.ImageResource(name: "stopRecord", bundle: resourceBundle)

    /// The "waiting" asset catalog image resource.
    static let waiting = DeveloperToolsSupport.ImageResource(name: "waiting", bundle: resourceBundle)

}

