#import <Foundation/Foundation.h>

@interface PDAudioPlayer : NSObject
- (void)enqueuePCM:(NSData *)data;
- (void)enqueuePCM:(NSData *)data sequence:(uint32_t)sequence timestampUS:(uint64_t)timestampUS;
- (void)reset;
@end
