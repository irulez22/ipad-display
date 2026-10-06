#import <Foundation/Foundation.h>

@interface PDAudioPlayer : NSObject
- (void)enqueuePCM:(NSData *)data;
- (void)reset;
@end
