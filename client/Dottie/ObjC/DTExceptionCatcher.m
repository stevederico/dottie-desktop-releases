//
//  DTExceptionCatcher.m
//  Dottie
//

#import "DTExceptionCatcher.h"

NSError *_Nullable DTTryBlock(void (^block)(void)) {
    @try {
        block();
        return nil;
    }
    @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
        info[@"exceptionName"] = exception.name;
        if (exception.reason) {
            info[@"exceptionReason"] = exception.reason;
        }
        return [NSError errorWithDomain:@"AVAudioTap" code:-1 userInfo:info];
    }
}
