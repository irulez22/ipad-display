#import <Foundation/Foundation.h>
#import "PDH264Parser.h"
#include <assert.h>

@interface Collector : NSObject <PDH264ParserDelegate>
@property(nonatomic,strong) NSMutableArray *units;
@end
@implementation Collector
- (instancetype)init { if((self=[super init])) _units=[NSMutableArray array]; return self; }
- (void)h264Parser:(PDH264Parser *)parser didOutputNALUnit:(NSData *)nal type:(uint8_t)type
{
    assert(type == (((const uint8_t *)nal.bytes)[0] & 31));
    [self.units addObject:nal];
}
@end

int main(void)
{
    @autoreleasepool {
        PDH264Parser *parser = [PDH264Parser new];
        Collector *collector = [Collector new];
        parser.delegate = collector;
        const uint8_t stream[] = {99, 0,0,0,1, 0x67,42, 0,0,1, 0x68,43, 0,0,0,1, 0x65,44};
        for(NSUInteger chunk=1; chunk<=sizeof(stream); chunk++){
            [parser reset]; [collector.units removeAllObjects];
            for(NSUInteger i=0;i<sizeof(stream);i+=chunk)
                [parser appendData:[NSData dataWithBytes:stream+i length:MIN(chunk,sizeof(stream)-i)]];
            [parser flush];
            assert(collector.units.count == 3);
            const uint8_t expected[][2]={{0x67,42},{0x68,43},{0x65,44}};
            for(NSUInteger i=0;i<3;i++)
                assert([collector.units[i] isEqualToData:[NSData dataWithBytes:expected[i] length:2]]);
        }
        [collector.units removeAllObjects];
        NSMutableData *oversized=[NSMutableData dataWithLength:8*1024*1024+5];
        uint8_t *bytes=oversized.mutableBytes; bytes[2]=1; bytes[3]=0x65;
        [parser appendData:oversized]; [parser flush];
        assert(collector.units.count == 0);
        [parser appendData:[NSData dataWithBytes:stream length:sizeof(stream)]];
        [parser flush];
        assert(collector.units.count == 3);
        [parser appendData:[NSData dataWithBytes:stream length:7]];
        [parser reset]; [collector.units removeAllObjects]; [parser flush];
        assert(collector.units.count == 0);
        NSLog(@"H.264 parser checks passed");
    }
    return 0;
}
