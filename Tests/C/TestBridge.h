// Bridge header for the test binary: everything the daemon sees, plus the
// gesture-event synthesizer the tests build trackpad CGEvents with.
// TouchEvents.{c,h} + IOHIDEventData.h + IOHIDEventTypes.h are copied verbatim
// from Hammerspoon (extensions/eventtap/). Undocumented private SPI — do not
// "clean up" these files. The daemon itself never synthesizes gestures, so they
// are compiled into the tests only.

#ifndef TestBridge_h
#define TestBridge_h

#include "../../Sources/C/StackdBridge.h"
#include "TouchEvents.h"

#endif
