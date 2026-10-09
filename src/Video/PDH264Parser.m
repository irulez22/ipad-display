#import "PDH264Parser.h"

static const NSUInteger PDMaximumNAL = 8 * 1024 * 1024;

@interface PDH264Parser ()
@property(nonatomic,strong) NSMutableData *buffer;
@end

@implementation PDH264Parser
- (instancetype)init
{
    if ((self = [super init])) _buffer = [NSMutableData data];
    return self;
}

static NSRange FindStartCode(const uint8_t *bytes, NSUInteger length, NSUInteger offset)
{
    for (NSUInteger i = offset; i + 3 <= length; i++) {
        if (bytes[i] != 0 || bytes[i + 1] != 0) continue;
        if (bytes[i + 2] == 1) return NSMakeRange(i, 3);
        if (i + 3 < length && bytes[i + 2] == 0 && bytes[i + 3] == 1)
            return NSMakeRange(i, 4);
    }
    return NSMakeRange(NSNotFound, 0);
}

- (void)emitNAL:(NSData *)nal
{
    if (!nal.length || nal.length > PDMaximumNAL) return;
    uint8_t type = ((const uint8_t *)nal.bytes)[0] & 0x1F;
    [self.delegate h264Parser:self didOutputNALUnit:nal type:type];
}

- (void)appendData:(NSData *)data
{
    if (!data.length) return;
    [self.buffer appendData:data];
    while (self.buffer.length >= 4) {
        NSRange first = FindStartCode(self.buffer.bytes, self.buffer.length, 0);
        if (first.location == NSNotFound) {
            // Keep a possible partial start code across TCP packet boundaries.
            [self.buffer replaceBytesInRange:NSMakeRange(0, self.buffer.length - 3)
                                  withBytes:NULL length:0];
            return;
        }
        if (first.location > 0) {
            [self.buffer replaceBytesInRange:NSMakeRange(0, first.location)
                                  withBytes:NULL length:0];
            continue;
        }
        NSRange next = FindStartCode(self.buffer.bytes, self.buffer.length, first.length);
        if (next.location == NSNotFound) {
            if (self.buffer.length > PDMaximumNAL + first.length) {
                [self.buffer replaceBytesInRange:NSMakeRange(0, self.buffer.length - 3)
                                      withBytes:NULL length:0];
            }
            return;
        }
        [self emitNAL:[self.buffer subdataWithRange:
            NSMakeRange(first.length, next.location - first.length)]];
        [self.buffer replaceBytesInRange:NSMakeRange(0, next.location)
                              withBytes:NULL length:0];
    }
}

- (void)flush
{
    NSRange first = FindStartCode(self.buffer.bytes, self.buffer.length, 0);
    if (first.location != NSNotFound) {
        NSUInteger start = first.location + first.length;
        [self emitNAL:[self.buffer subdataWithRange:NSMakeRange(start, self.buffer.length - start)]];
    }
    [self reset];
}

- (void)reset
{
    [self.buffer setLength:0];
}
@end
