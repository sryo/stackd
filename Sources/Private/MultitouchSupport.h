// MultitouchSupport.framework — private SPI for raw per-finger trackpad
// frames. Vendored from asmagill's hs._asm.undocumented.touchdevice
// (MultitouchSupport.h, "Tested against 10.12.6"), trimmed to what
// TouchDevice.swift actually calls. Cross-checked on macOS 13/14/15:
// struct layout has not shifted since 10.12.
//
// Sources cited by asmagill:
//   https://github.com/INRIA/libpointing/blob/master/pointing/input/osx/osxPrivateMultitouchSupport.h
//   https://github.com/calftrail/Touch
//   https://github.com/jnordberg/FingerMgmt
//
// Linked via `-framework MultitouchSupport`. The framework lives at
// /System/Library/PrivateFrameworks/MultitouchSupport.framework and is
// found by the toolchain via the standard private-framework search path.

#ifndef MultitouchSupport_h
#define MultitouchSupport_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// MTDeviceRef is really a CFTypeRef under the hood, but we expose it to
// Swift as an opaque void* so the toll-free CF→ObjC bridging doesn't kick
// in and force us through Unmanaged. That lets us call MTDeviceRelease
// directly (the framework expects manual retain/release for these handles,
// not Swift ARC). asmagill's Lua bridge uses the same pattern.
typedef void *MTDeviceRef;

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef enum {
    MTPathStageNotTracking   = 0,
    MTPathStageStartInRange  = 1,
    MTPathStageHoverInRange  = 2,
    MTPathStageMakeTouch     = 3,
    MTPathStageTouching      = 4,
    MTPathStageBreakTouch    = 5,
    MTPathStageLingerInRange = 6,
    MTPathStageOutOfRange    = 7
} MTPathStage;

// MTTouch field offsets MUST match the runtime layout exactly — a wrong
// offset = segfault on first frame. Order/types verified against
// asmagill's header and FingerMgmt; stable across macOS 10.12 → 15.
typedef struct {
    int32_t     frame;
    double      timestamp;
    int32_t     pathIndex;        // transducer index ("P")
    MTPathStage stage;
    int32_t     fingerID;         // stable per-finger across frames ("F")
    int32_t     handID;           // always 1 in practice ("H")
    MTVector    normalizedVector; // position + velocity, 0..1 trackpad-relative
    float       zTotal;           // ~surface area (0..1, multiple of 1/8)
    float       zPressure;        // force-touch pressure; 0 on non-force devices
    float       angle;            // major-axis radians
    float       majorAxis;        // ellipsoid major axis (mm)
    float       minorAxis;        // ellipsoid minor axis (mm)
    MTVector    absoluteVector;   // position + velocity in mm
    int32_t     field14;          // observed 0
    int32_t     field15;          // observed 0
    float       zDensity;         // touch density
} MTTouch;

typedef void (*MTFrameCallbackFunction)(MTDeviceRef device,
                                        MTTouch *touches,
                                        size_t numTouches,
                                        double timestamp,
                                        size_t frame,
                                        void *refcon);

extern MTDeviceRef MTDeviceCreateDefault(void);
extern void        MTDeviceRelease(MTDeviceRef device);

extern OSStatus    MTDeviceStart(MTDeviceRef device, int32_t runMode);
extern OSStatus    MTDeviceStop(MTDeviceRef device);
extern Boolean     MTDeviceIsRunning(MTDeviceRef device);

// Refcon variant lets us pass an opaque pointer to the Swift singleton
// instead of relying on global state. Non-refcon Register/Unregister
// exist too but asmagill's code uses the refcon path for the same reason.
extern Boolean     MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef device,
                                                            MTFrameCallbackFunction callback,
                                                            void *refcon);
extern Boolean     MTUnregisterContactFrameCallback(MTDeviceRef device,
                                                    MTFrameCallbackFunction callback);

#endif
