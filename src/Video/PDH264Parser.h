#import <Foundation/Foundation.h>
@class PDH264Parser;
@protocol PDH264ParserDelegate <NSObject>
- (void)h264Parser:(PDH264Parser *)parser didOutputNALUnit:(NSData *)nalUnit type:(uint8_t)type;
@end
@interface PDH264Parser:NSObject
@property(nonatomic,weak) id<PDH264ParserDelegate> delegate;
- (void)appendData:(NSData*)data;
- (void)flush;
- (void)reset;
@end
