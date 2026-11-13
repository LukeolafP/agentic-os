//
//  ObjCExceptionCatcher.h
//  Agentic OS
//
//  Swift cannot catch an Objective-C exception. AVAudioEngine throws one from installTap when the
//  microphone's sample rate changes while it opens (a Bluetooth headset switching into call mode),
//  and AppKit swallowed it mid-task: the main actor's work stopped, ⌃⌥ went deaf, and the next
//  click on the island crashed in SwiftUI's hit test (13 Nov 2026). Run such calls through this.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`; returns nil, or the exception it threw.
NSException * _Nullable AgenticOSCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
