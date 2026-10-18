// Bridge header exposing C symbols to Swift via -import-objc-header.

#ifndef StackdBridge_h
#define StackdBridge_h

// Importing the umbrella here also makes CoreGraphics (CGEvent, CGWindowID,
// ...) visible to every Swift file without a per-file import.
#include <ApplicationServices/ApplicationServices.h>
#include "../Private/MultitouchSupport.h"
#import "SafePredicate.h"

#endif
