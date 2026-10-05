#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
@class PDVideoDecoder;
@protocol PDVideoDecoderDelegate <NSObject>
- (void)videoDecoder:(PDVideoDecoder *)decoder didUpdateStatus:(NSString *)status;
@end
@interface PDVideoDecoder:NSObject
@property(nonatomic,weak) id<PDVideoDecoderDelegate> delegate;
- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer*)layer;
- (void)decodeNALUnit:(NSData*)nalUnit type:(uint8_t)type;
- (void)flush;
- (void)reset;
@end
