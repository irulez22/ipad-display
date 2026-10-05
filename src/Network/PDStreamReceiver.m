#import "PDStreamReceiver.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

static const uint32_t PDMaximumPayload = 8 * 1024 * 1024;

@interface PDStreamReceiver ()
@property(nonatomic) uint16_t port;
@property(nonatomic) int listenFD;
@property(nonatomic) int clientFD;
@property(nonatomic,strong) dispatch_queue_t queue;
@end

@implementation PDStreamReceiver

- (instancetype)initWithPort:(uint16_t)p
{
    if ((self = [super init])) {
        _port = p;
        _listenFD = -1;
        _clientFD = -1;
        _queue = dispatch_queue_create("com.ipaddisplay.receiver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)readExactly:(void *)buffer length:(size_t)length fd:(int)fd
{
    uint8_t *p = buffer;
    size_t left = length;
    while (left) {
        ssize_t count = recv(fd, p, left, 0);
        if (count <= 0) return NO;
        p += count;
        left -= (size_t)count;
    }
    return YES;
}

- (BOOL)sendExactly:(const void *)buffer length:(size_t)length fd:(int)fd
{
    const uint8_t *p = buffer;
    size_t left = length;
    while (left) {
        ssize_t count = send(fd, p, left, 0);
        if (count <= 0) return NO;
        p += count;
        left -= (size_t)count;
    }
    return YES;
}

- (BOOL)sendPacketType:(uint8_t)type payload:(NSData *)payload
{
    @synchronized (self) {
        int fd = self.clientFD;
        if (fd < 0) return NO;

        uint32_t length = (uint32_t)payload.length;
        uint32_t networkLength = htonl(length);
        uint8_t header[5];
        memcpy(header, &networkLength, 4);
        header[4] = type;

        if (![self sendExactly:header length:sizeof(header) fd:fd]) return NO;
        if (length && ![self sendExactly:payload.bytes length:length fd:fd]) return NO;
        return YES;
    }
}

- (void)start
{
    dispatch_async(self.queue, ^{
        [self runServer];
    });
}

- (void)runServer
{
    self.listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (self.listenFD < 0) return;

    int yes = 1;
    setsockopt(self.listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(self.port);

    if (bind(self.listenFD, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(self.listenFD, 1) != 0) {
        close(self.listenFD);
        self.listenFD = -1;
        return;
    }

    while (self.listenFD >= 0) {
        int client = accept(self.listenFD, NULL, NULL);
        if (client < 0) continue;

        self.clientFD = client;
        id<PDStreamReceiverDelegate> delegate = self.delegate;
        [delegate streamReceiverDidConnect:self];

        while (self.clientFD == client) {
            uint32_t networkLength = 0;
            uint8_t type = 0;
            if (![self readExactly:&networkLength length:4 fd:client]) break;

            uint32_t length = ntohl(networkLength);
            if (length > PDMaximumPayload) break;
            if (![self readExactly:&type length:1 fd:client]) break;

            NSMutableData *payload = [NSMutableData dataWithLength:length];
            if (length && ![self readExactly:payload.mutableBytes length:length fd:client]) break;
            [delegate streamReceiver:self didReceivePacketType:type payload:payload];
        }

        shutdown(client, SHUT_RDWR);
        close(client);
        if (self.clientFD == client) self.clientFD = -1;
        [delegate streamReceiverDidDisconnect:self error:nil];
    }
}

- (void)disconnectClient
{
    @synchronized (self) {
        int fd = self.clientFD;
        self.clientFD = -1;
        if (fd >= 0) shutdown(fd, SHUT_RDWR);
    }
}

- (void)stop
{
    [self disconnectClient];
    int fd = self.listenFD;
    self.listenFD = -1;
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

- (void)dealloc
{
    [self stop];
}

@end
