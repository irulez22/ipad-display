#import "PDH264Parser.h"
@interface PDH264Parser () @property(nonatomic,strong) NSMutableData*buffer; @end
@implementation PDH264Parser
- (instancetype)init{if((self=[super init]))_buffer=[NSMutableData data];return self;}
static NSRange FindSC(const uint8_t*b,NSUInteger n,NSUInteger o){for(NSUInteger i=o;i+3<=n;i++)if(b[i]==0&&b[i+1]==0){if(b[i+2]==1)return NSMakeRange(i,3);if(i+3<n&&b[i+2]==0&&b[i+3]==1)return NSMakeRange(i,4);}return NSMakeRange(NSNotFound,0);}
- (void)emitNAL:(NSData*)n{if(!n.length)return;uint8_t t=((const uint8_t*)n.bytes)[0]&0x1F;[self.delegate h264Parser:self didOutputNALUnit:n type:t];}
- (void)appendData:(NSData*)d{if(!d.length)return;[self.buffer appendData:d];while(self.buffer.length>=4){const uint8_t*b=self.buffer.bytes;NSRange f=FindSC(b,self.buffer.length,0);if(f.location==NSNotFound){if(self.buffer.length>4)[self.buffer replaceBytesInRange:NSMakeRange(0,self.buffer.length-4) withBytes:NULL length:0];return;}if(f.location>0){[self.buffer replaceBytesInRange:NSMakeRange(0,f.location) withBytes:NULL length:0];continue;}b=self.buffer.bytes;NSRange s=FindSC(b,self.buffer.length,f.length);if(s.location==NSNotFound)return;NSUInteger start=f.length,len=s.location-start;if(len)[self emitNAL:[self.buffer subdataWithRange:NSMakeRange(start,len)]];[self.buffer replaceBytesInRange:NSMakeRange(0,s.location) withBytes:NULL length:0];}}
- (void)flush{if(!self.buffer.length)return;const uint8_t*b=self.buffer.bytes;NSRange f=FindSC(b,self.buffer.length,0);if(f.location!=NSNotFound){NSUInteger start=f.location+f.length;if(start<self.buffer.length)[self emitNAL:[self.buffer subdataWithRange:NSMakeRange(start,self.buffer.length-start)]];}[self.buffer setLength:0];}
- (void)reset{[self.buffer setLength:0];}
@end
