#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void PDLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
FOUNDATION_EXPORT double PDMemoryMB(void);
FOUNDATION_EXPORT NSString *PDLogFilePath(void);
