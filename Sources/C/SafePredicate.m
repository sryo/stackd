#import "SafePredicate.h"

NSPredicate * _Nullable StackdSafeNSPredicate(NSString * _Nonnull format,
                                              NSString * _Nullable * _Nullable errorOut) {
    @try {
        return [NSPredicate predicateWithFormat:format];
    } @catch (NSException *e) {
        if (errorOut) { *errorOut = e.reason ?: e.name; }
        return nil;
    }
}
