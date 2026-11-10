#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"chat.ExyteChat";

/// The "inputBG" asset catalog color resource.
static NSString * const ACColorNameInputBG AC_SWIFT_PRIVATE = @"inputBG";

/// The "inputPlaceholderText" asset catalog color resource.
static NSString * const ACColorNameInputPlaceholderText AC_SWIFT_PRIVATE = @"inputPlaceholderText";

/// The "mainBG" asset catalog color resource.
static NSString * const ACColorNameMainBG AC_SWIFT_PRIVATE = @"mainBG";

/// The "mainCaptionText" asset catalog color resource.
static NSString * const ACColorNameMainCaptionText AC_SWIFT_PRIVATE = @"mainCaptionText";

/// The "mainText" asset catalog color resource.
static NSString * const ACColorNameMainText AC_SWIFT_PRIVATE = @"mainText";

/// The "menuBG" asset catalog color resource.
static NSString * const ACColorNameMenuBG AC_SWIFT_PRIVATE = @"menuBG";

/// The "menuText" asset catalog color resource.
static NSString * const ACColorNameMenuText AC_SWIFT_PRIVATE = @"menuText";

/// The "menuTextDelete" asset catalog color resource.
static NSString * const ACColorNameMenuTextDelete AC_SWIFT_PRIVATE = @"menuTextDelete";

/// The "messageFriendBG" asset catalog color resource.
static NSString * const ACColorNameMessageFriendBG AC_SWIFT_PRIVATE = @"messageFriendBG";

/// The "messageFriendTimeText" asset catalog color resource.
static NSString * const ACColorNameMessageFriendTimeText AC_SWIFT_PRIVATE = @"messageFriendTimeText";

/// The "messageMyBG" asset catalog color resource.
static NSString * const ACColorNameMessageMyBG AC_SWIFT_PRIVATE = @"messageMyBG";

/// The "messageMyTimeText" asset catalog color resource.
static NSString * const ACColorNameMessageMyTimeText AC_SWIFT_PRIVATE = @"messageMyTimeText";

/// The "messageReadStatus" asset catalog color resource.
static NSString * const ACColorNameMessageReadStatus AC_SWIFT_PRIVATE = @"messageReadStatus";

/// The "statusError" asset catalog color resource.
static NSString * const ACColorNameStatusError AC_SWIFT_PRIVATE = @"statusError";

/// The "statusGray" asset catalog color resource.
static NSString * const ACColorNameStatusGray AC_SWIFT_PRIVATE = @"statusGray";

/// The "MuteVideo" asset catalog image resource.
static NSString * const ACImageNameMuteVideo AC_SWIFT_PRIVATE = @"MuteVideo";

/// The "Poweredby_100px-Black_VertText" asset catalog image resource.
static NSString * const ACImageNamePoweredby100PxBlackVertText AC_SWIFT_PRIVATE = @"Poweredby_100px-Black_VertText";

/// The "Poweredby_100px-White_VertText" asset catalog image resource.
static NSString * const ACImageNamePoweredby100PxWhiteVertText AC_SWIFT_PRIVATE = @"Poweredby_100px-White_VertText";

/// The "add" asset catalog image resource.
static NSString * const ACImageNameAdd AC_SWIFT_PRIVATE = @"add";

/// The "arrowSend" asset catalog image resource.
static NSString * const ACImageNameArrowSend AC_SWIFT_PRIVATE = @"arrowSend";

/// The "attach" asset catalog image resource.
static NSString * const ACImageNameAttach AC_SWIFT_PRIVATE = @"attach";

/// The "attachCamera" asset catalog image resource.
static NSString * const ACImageNameAttachCamera AC_SWIFT_PRIVATE = @"attachCamera";

/// The "attachedDocument" asset catalog image resource.
static NSString * const ACImageNameAttachedDocument AC_SWIFT_PRIVATE = @"attachedDocument";

/// The "backArrow" asset catalog image resource.
static NSString * const ACImageNameBackArrow AC_SWIFT_PRIVATE = @"backArrow";

/// The "camera" asset catalog image resource.
static NSString * const ACImageNameCamera AC_SWIFT_PRIVATE = @"camera";

/// The "cancelRecord" asset catalog image resource.
static NSString * const ACImageNameCancelRecord AC_SWIFT_PRIVATE = @"cancelRecord";

/// The "cancelReply" asset catalog image resource.
static NSString * const ACImageNameCancelReply AC_SWIFT_PRIVATE = @"cancelReply";

/// The "chevronDown" asset catalog image resource.
static NSString * const ACImageNameChevronDown AC_SWIFT_PRIVATE = @"chevronDown";

/// The "chevronRight" asset catalog image resource.
static NSString * const ACImageNameChevronRight AC_SWIFT_PRIVATE = @"chevronRight";

/// The "contact" asset catalog image resource.
static NSString * const ACImageNameContact AC_SWIFT_PRIVATE = @"contact";

/// The "cross" asset catalog image resource.
static NSString * const ACImageNameCross AC_SWIFT_PRIVATE = @"cross";

/// The "delete" asset catalog image resource.
static NSString * const ACImageNameDelete AC_SWIFT_PRIVATE = @"delete";

/// The "deleteRecord" asset catalog image resource.
static NSString * const ACImageNameDeleteRecord AC_SWIFT_PRIVATE = @"deleteRecord";

/// The "document" asset catalog image resource.
static NSString * const ACImageNameDocument AC_SWIFT_PRIVATE = @"document";

/// The "edit" asset catalog image resource.
static NSString * const ACImageNameEdit AC_SWIFT_PRIVATE = @"edit";

/// The "forward" asset catalog image resource.
static NSString * const ACImageNameForward AC_SWIFT_PRIVATE = @"forward";

/// The "location" asset catalog image resource.
static NSString * const ACImageNameLocation AC_SWIFT_PRIVATE = @"location";

/// The "lockRecord" asset catalog image resource.
static NSString * const ACImageNameLockRecord AC_SWIFT_PRIVATE = @"lockRecord";

/// The "microphone" asset catalog image resource.
static NSString * const ACImageNameMicrophone AC_SWIFT_PRIVATE = @"microphone";

/// The "pauseAudio" asset catalog image resource.
static NSString * const ACImageNamePauseAudio AC_SWIFT_PRIVATE = @"pauseAudio";

/// The "pauseRecord" asset catalog image resource.
static NSString * const ACImageNamePauseRecord AC_SWIFT_PRIVATE = @"pauseRecord";

/// The "photo" asset catalog image resource.
static NSString * const ACImageNamePhoto AC_SWIFT_PRIVATE = @"photo";

/// The "pickDocument" asset catalog image resource.
static NSString * const ACImageNamePickDocument AC_SWIFT_PRIVATE = @"pickDocument";

/// The "pickLocation" asset catalog image resource.
static NSString * const ACImageNamePickLocation AC_SWIFT_PRIVATE = @"pickLocation";

/// The "pickPhoto" asset catalog image resource.
static NSString * const ACImageNamePickPhoto AC_SWIFT_PRIVATE = @"pickPhoto";

/// The "playAudio" asset catalog image resource.
static NSString * const ACImageNamePlayAudio AC_SWIFT_PRIVATE = @"playAudio";

/// The "playRecord" asset catalog image resource.
static NSString * const ACImageNamePlayRecord AC_SWIFT_PRIVATE = @"playRecord";

/// The "reply" asset catalog image resource.
static NSString * const ACImageNameReply AC_SWIFT_PRIVATE = @"reply";

/// The "replyToMessage" asset catalog image resource.
static NSString * const ACImageNameReplyToMessage AC_SWIFT_PRIVATE = @"replyToMessage";

/// The "retry" asset catalog image resource.
static NSString * const ACImageNameRetry AC_SWIFT_PRIVATE = @"retry";

/// The "save" asset catalog image resource.
static NSString * const ACImageNameSave AC_SWIFT_PRIVATE = @"save";

/// The "scrollToBottom" asset catalog image resource.
static NSString * const ACImageNameScrollToBottom AC_SWIFT_PRIVATE = @"scrollToBottom";

/// The "select" asset catalog image resource.
static NSString * const ACImageNameSelect AC_SWIFT_PRIVATE = @"select";

/// The "sendRecord" asset catalog image resource.
static NSString * const ACImageNameSendRecord AC_SWIFT_PRIVATE = @"sendRecord";

/// The "sticker" asset catalog image resource.
static NSString * const ACImageNameSticker AC_SWIFT_PRIVATE = @"sticker";

/// The "stopRecord" asset catalog image resource.
static NSString * const ACImageNameStopRecord AC_SWIFT_PRIVATE = @"stopRecord";

/// The "waiting" asset catalog image resource.
static NSString * const ACImageNameWaiting AC_SWIFT_PRIVATE = @"waiting";

/// The "check" asset catalog image resource.
static NSString * const ACImageNameCheck AC_SWIFT_PRIVATE = @"check";

/// The "checkAll" asset catalog image resource.
static NSString * const ACImageNameCheckAll AC_SWIFT_PRIVATE = @"checkAll";

#undef AC_SWIFT_PRIVATE
