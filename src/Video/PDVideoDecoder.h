#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
@interface PDVideoDecoder:NSObject
- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer*)layer; - (void)decodeNALUnit:(NSData*)nalUnit type:(uint8_t)type; - (void)reset;
@end
