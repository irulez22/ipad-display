#import <Foundation/Foundation.h>
@class PDStreamReceiver;
@protocol PDStreamReceiverDelegate <NSObject>
- (void)streamReceiverDidConnect:(PDStreamReceiver *)receiver;
- (void)streamReceiverDidDisconnect:(PDStreamReceiver *)receiver error:(NSError *)error;
- (void)streamReceiver:(PDStreamReceiver *)receiver didReceivePacketType:(uint8_t)type payload:(NSData *)payload;
@end

@interface PDStreamReceiver : NSObject
@property(nonatomic,weak) id<PDStreamReceiverDelegate> delegate;
- (instancetype)initWithPort:(uint16_t)port;
- (void)start;
- (void)stop;
- (void)disconnectClient;
- (BOOL)sendPacketType:(uint8_t)type payload:(NSData *)payload;
@end
