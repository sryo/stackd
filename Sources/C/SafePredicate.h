// Swift can't catch Objective-C exceptions. NSPredicate.init(format:) raises
// NSInvalidArgumentException on malformed format strings, which propagates
// past every Swift try/catch and crashes the daemon. This trampoline wraps
// the call in @try/@catch and returns nil on exception instead.
//
// Use whenever a primitive accepts a user-authored predicate string —
// Spotlight queries today; future calendar predicates, AX queries, etc.

#ifndef StackdSafePredicate_h
#define StackdSafePredicate_h

#import <Foundation/Foundation.h>

/// Build an NSPredicate from `format`, returning nil on parse exception
/// instead of crashing. `errorOut` (optional) receives the localized
/// NSException reason for logging / surfacing to the caller.
NSPredicate * _Nullable StackdSafeNSPredicate(NSString * _Nonnull format,
                                              NSString * _Nullable * _Nullable errorOut);

#endif
