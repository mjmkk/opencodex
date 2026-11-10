#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"mediapicker.ExyteMediaPicker";

/// The "cameraBG" asset catalog color resource.
static NSString * const ACColorNameCameraBG AC_SWIFT_PRIVATE = @"cameraBG";

/// The "cameraText" asset catalog color resource.
static NSString * const ACColorNameCameraText AC_SWIFT_PRIVATE = @"cameraText";

/// The "pickerBG" asset catalog color resource.
static NSString * const ACColorNamePickerBG AC_SWIFT_PRIVATE = @"pickerBG";

/// The "pickerText" asset catalog color resource.
static NSString * const ACColorNamePickerText AC_SWIFT_PRIVATE = @"pickerText";

/// The "selection" asset catalog color resource.
static NSString * const ACColorNameSelection AC_SWIFT_PRIVATE = @"selection";

/// The "FlashOff" asset catalog image resource.
static NSString * const ACImageNameFlashOff AC_SWIFT_PRIVATE = @"FlashOff";

/// The "FlashOn" asset catalog image resource.
static NSString * const ACImageNameFlashOn AC_SWIFT_PRIVATE = @"FlashOn";

/// The "FlipCamera" asset catalog image resource.
static NSString * const ACImageNameFlipCamera AC_SWIFT_PRIVATE = @"FlipCamera";

#undef AC_SWIFT_PRIVATE
