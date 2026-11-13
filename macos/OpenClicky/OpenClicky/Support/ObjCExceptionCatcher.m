//
//  ObjCExceptionCatcher.m
//  Agentic OS
//

#import "ObjCExceptionCatcher.h"

NSException * _Nullable AgenticOSCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
