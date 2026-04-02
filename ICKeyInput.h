// ICKeyInput.h — HID Keyboard input dispatch for IOSControl daemon
// Injects keyboard events via IOHIDEvent (same pathway as touch dispatch)

#pragma once
#import <Foundation/Foundation.h>

// Press a single key by HID usage page + usage code
// Returns YES if dispatch succeeded
BOOL ic_keyPress(uint32_t usagePage, uint32_t usage);

// Type a UTF-8 text string (key-by-key, basic ASCII)
// Returns YES if all chars dispatched
BOOL ic_keyInputText(NSString *text);

// Common key codes (HID Consumer/Keyboard pages)
// Usage page 0x07 = Keyboard, 0x0C = Consumer
typedef NS_ENUM(uint32_t, ICKeyCode) {
  // Keyboard page (0x07)
  ICKeyReturn = 0x28,
  ICKeyEscape = 0x29,
  ICKeyBackspace = 0x2A,
  ICKeyTab = 0x2B,
  ICKeySpace = 0x2C,
  ICKeyHome = 0x4A,
  ICKeyEnd = 0x4D,
  ICKeyDelete = 0x4C,
  ICKeyUpArrow = 0x52,
  ICKeyDownArrow = 0x51,
  ICKeyLeftArrow = 0x50,
  ICKeyRightArrow = 0x4F,
  // Consumer page (0x0C)
  ICKeyVolumeUp = 0xE9,
  ICKeyVolumeDown = 0xEA,
  ICKeyMute = 0xE2,
  ICKeyHome_C = 0x40, // Home button (consumer)
};
