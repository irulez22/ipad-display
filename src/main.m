#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "PDLog.h"

static void PDUncaughtExceptionHandler(NSException *exception)
{
    PDLog(@"UNCAUGHT EXCEPTION %@ reason=%@ stack=%@", exception.name, exception.reason, exception.callStackSymbols);
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&PDUncaughtExceptionHandler);
        PDLog(@"Process start");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
