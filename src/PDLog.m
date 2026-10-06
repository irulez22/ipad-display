#import "PDLog.h"
#import <mach/mach.h>

static NSString *PDResolveLogPath(void)
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject;
    if (!dir.length) dir = NSTemporaryDirectory();
    if (!dir.length) dir = @"/tmp";
    return [dir stringByAppendingPathComponent:@"PadDisplay.log"];
}

NSString *PDLogFilePath(void)
{
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        path = [PDResolveLogPath() copy];
    });
    return path;
}

double PDMemoryMB(void)
{
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return -1.0;
    return ((double)info.resident_size) / (1024.0 * 1024.0);
}

void PDLog(NSString *format, ...)
{
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *thread = [NSThread isMainThread] ? @"main" : @"bg";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] mem=%.1fMB %@\n", timestamp, thread, PDMemoryMB(), message];

    NSLog(@"%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);

    @synchronized ([NSFileManager class]) {
        NSString *path = PDLogFilePath();
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs fileSize];
        if (size > (2ULL * 1024ULL * 1024ULL)) {
            NSString *old = [path stringByAppendingString:@".old"];
            [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:old error:nil];
        }

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    }
}
