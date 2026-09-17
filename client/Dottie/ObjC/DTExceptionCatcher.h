//
//  DTExceptionCatcher.h
//  Dottie
//
//  Objective-C bridge that catches NSExceptions Swift cannot.
//
//  AVFoundation APIs like -[AVAudioNode installTapOnBus:bufferSize:format:block:]
//  raise Objective-C NSExceptions (not NSErrors) when given a format that doesn't
//  match the input node's current hardware format — which happens when CoreAudio
//  is mid-device-switch (route change, sleep/wake, AggregateDevice rebuild). Swift
//  has no `catch` for ObjC exceptions, so such a throw unwinds past Swift's
//  `do/catch`, hits `std::terminate`, and aborts the process (SIGABRT).
//
//  Wrapping the call in `DTTryBlock` converts that uncatchable throw into a
//  returned NSError the Swift caller can handle (teardown + backoff/retry).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch.
/// - Returns: `nil` if the block completed normally, or an `NSError` describing
///   the caught `NSException` (domain `AVAudioTap`). Re-raises nothing.
NSError *_Nullable DTTryBlock(void (^block)(void));

NS_ASSUME_NONNULL_END
