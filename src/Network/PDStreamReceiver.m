#import "PDStreamReceiver.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
static const uint32_t PDMaximumPayload=8*1024*1024;
@interface PDStreamReceiver ()
@property(nonatomic) uint16_t port; @property(nonatomic) int listenFD; @property(nonatomic) int clientFD; @property(nonatomic,strong) dispatch_queue_t queue;
@end
@implementation PDStreamReceiver
- (instancetype)initWithPort:(uint16_t)p { if((self=[super init])){_port=p;_listenFD=-1;_clientFD=-1;_queue=dispatch_queue_create("com.ipaddisplay.receiver",DISPATCH_QUEUE_SERIAL);}return self; }
- (BOOL)readExactly:(void*)b length:(size_t)n fd:(int)fd { uint8_t*p=b; size_t left=n; while(left){ssize_t c=recv(fd,p,left,0);if(c<=0)return NO;p+=c;left-=(size_t)c;}return YES; }
- (void)start { dispatch_async(self.queue, ^{[self runServer];}); }
- (void)runServer { self.listenFD=socket(AF_INET,SOCK_STREAM,0);if(self.listenFD<0)return;int yes=1;setsockopt(self.listenFD,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));struct sockaddr_in a;memset(&a,0,sizeof(a));a.sin_family=AF_INET;a.sin_addr.s_addr=htonl(INADDR_ANY);a.sin_port=htons(self.port);if(bind(self.listenFD,(struct sockaddr*)&a,sizeof(a))!=0||listen(self.listenFD,1)!=0){close(self.listenFD);self.listenFD=-1;return;}while(self.listenFD>=0){int c=accept(self.listenFD,NULL,NULL);if(c<0)continue;self.clientFD=c;id<PDStreamReceiverDelegate>d=self.delegate;[d streamReceiverDidConnect:self];while(self.clientFD>=0){uint32_t nl=0;uint8_t type=0;if(![self readExactly:&nl length:4 fd:c])break;uint32_t len=ntohl(nl);if(len>PDMaximumPayload)break;if(![self readExactly:&type length:1 fd:c])break;NSMutableData*p=[NSMutableData dataWithLength:len];if(len&&![self readExactly:p.mutableBytes length:len fd:c])break;[d streamReceiver:self didReceivePacketType:type payload:p];}if(c>=0)close(c);self.clientFD=-1;[d streamReceiverDidDisconnect:self error:nil];} }
- (void)disconnectClient { int fd=self.clientFD;self.clientFD=-1;if(fd>=0){shutdown(fd,SHUT_RDWR);close(fd);} }
- (void)stop {[self disconnectClient];int fd=self.listenFD;self.listenFD=-1;if(fd>=0){shutdown(fd,SHUT_RDWR);close(fd);}}
- (void)dealloc {[self stop];}
@end
