// Bridge header exposing C symbols to Swift via -import-objc-header.
// TouchEvents.{c,h} + IOHIDEventData.h + IOHIDEventTypes.h are copied verbatim
// from Hammerspoon (extensions/eventtap/) per the refactorer's "preserve
// verbatim" rule for undocumented private SPI. Do not "clean up" these files.

#ifndef GlasspaneBridge_h
#define GlasspaneBridge_h

#include "TouchEvents.h"

#endif
