// Bridge header exposing C symbols to Swift via -import-objc-header.
// TouchEvents.{c,h} + IOHIDEventData.h + IOHIDEventTypes.h are copied verbatim
// from Hammerspoon (extensions/eventtap/) per the refactorer's "preserve
// verbatim" rule for undocumented private SPI. Do not "clean up" these files.

#ifndef StackdBridge_h
#define StackdBridge_h

#include "TouchEvents.h"
#include "../Private/MultitouchSupport.h"
#import "SafePredicate.h"

#endif
