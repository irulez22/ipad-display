#import "DisplayViewController.h"
#import "PDStreamReceiver.h"
#import "PDH264Parser.h"
#import "PDVideoDecoder.h"
#import "PDLog.h"
#import <AVFoundation/AVFoundation.h>

static const uint8_t PD_PACKET_TOUCH_V2 = 0x11;
static const uint8_t PD_TOUCH_DOWN = 0;
static const uint8_t PD_TOUCH_MOVE = 1;
static const uint8_t PD_TOUCH_UP = 2;
static const uint8_t PD_TOUCH_CANCEL = 3;
static const NSUInteger PD_MAX_TOUCHES = 10;

@interface DisplayViewController () <PDStreamReceiverDelegate, PDH264ParserDelegate, PDVideoDecoderDelegate>
@property(nonatomic,strong) AVSampleBufferDisplayLayer *displayLayer;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) PDStreamReceiver *receiver;
@property(nonatomic,strong) PDH264Parser *parser;
@property(nonatomic,strong) PDVideoDecoder *decoder;
@property(nonatomic,strong) NSMutableDictionary *touchIDs;
@property(nonatomic) uint16_t nextTouchID;
@property(nonatomic) BOOL videoReady;
@end

@implementation DisplayViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;
    self.touchIDs = [NSMutableDictionary dictionary];
    self.nextTouchID = 0;

    self.displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer:self.displayLayer];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"PadDisplay\nWaiting for connection on TCP 4822";
    [self.view addSubview:self.statusLabel];

    self.decoder = [[PDVideoDecoder alloc] initWithDisplayLayer:self.displayLayer];
    self.decoder.delegate = self;

    self.parser = [[PDH264Parser alloc] init];
    self.parser.delegate = self;

    self.receiver = [[PDStreamReceiver alloc] initWithPort:4822];
    self.receiver.delegate = self;
    PDLog(@"DisplayViewController ready; starting receiver");
    [self.receiver start];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    self.displayLayer.frame = self.view.bounds;
    self.statusLabel.frame = CGRectInset(self.view.bounds, 40, 40);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)shouldAutorotate { return YES; }

- (void)streamReceiverDidConnect:(PDStreamReceiver *)receiver
{
    PDLog(@"Receiver connected");
    self.videoReady = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Connected - waiting for H.264";
    });
}

- (void)streamReceiverDidDisconnect:(PDStreamReceiver *)receiver error:(NSError *)error
{
    PDLog(@"Receiver disconnected error=%@", error);
    self.videoReady = NO;
    [self.touchIDs removeAllObjects];
    [self.parser flush];
    [self.decoder flush];
    [self.decoder reset];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Disconnected - waiting for connection";
    });
}

- (void)streamReceiver:(PDStreamReceiver *)receiver didReceivePacketType:(uint8_t)type payload:(NSData *)payload
{
    if (type == 0x01) {
        [self.parser appendData:payload];
    } else if (type == 0x04) {
        PDLog(@"Host requested disconnect");
        [self.parser flush];
        [self.decoder flush];
        [receiver disconnectClient];
    }
}

- (void)h264Parser:(PDH264Parser *)parser didOutputNALUnit:(NSData *)nal type:(uint8_t)type
{
    [self.decoder decodeNALUnit:nal type:type];
}

- (void)videoDecoder:(PDVideoDecoder *)decoder didUpdateStatus:(NSString *)status
{
    if ([status hasPrefix:@"VideoToolbox OK"]) {
        self.videoReady = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.hidden = YES;
        });
        return;
    }

    if (self.videoReady) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.hidden = NO;
        self.statusLabel.text = [NSString stringWithFormat:@"PadDisplay\n%@", status];
    });
}

- (NSValue *)keyForTouch:(UITouch *)touch
{
    return [NSValue valueWithNonretainedObject:touch];
}

- (uint16_t)touchIDForTouch:(UITouch *)touch create:(BOOL)create
{
    NSValue *key = [self keyForTouch:touch];
    NSNumber *existing = self.touchIDs[key];
    if (existing) return (uint16_t)[existing unsignedIntValue];
    if (!create || self.touchIDs.count >= PD_MAX_TOUCHES) return UINT16_MAX;

    uint16_t candidate = self.nextTouchID++;
    self.touchIDs[key] = @(candidate);
    return candidate;
}

- (void)sendTouches:(NSSet *)touches phase:(uint8_t)phase
{
    if (!self.receiver || touches.count == 0 ||
        self.view.bounds.size.width <= 0 || self.view.bounds.size.height <= 0) return;

    NSMutableArray *encoded = [NSMutableArray array];
    for (UITouch *touch in touches) {
        BOOL create = (phase == PD_TOUCH_DOWN);
        uint16_t touchID = [self touchIDForTouch:touch create:create];
        if (touchID == UINT16_MAX) continue;

        CGPoint point = [touch locationInView:self.view];
        CGFloat nx = MIN(1.0, MAX(0.0, point.x / self.view.bounds.size.width));
        CGFloat ny = MIN(1.0, MAX(0.0, point.y / self.view.bounds.size.height));
        uint16_t x = (uint16_t)lrint(nx * 65535.0);
        uint16_t y = (uint16_t)lrint(ny * 65535.0);

        uint8_t bytes[7];
        bytes[0] = (uint8_t)(touchID >> 8);
        bytes[1] = (uint8_t)(touchID & 0xff);
        bytes[2] = phase;
        bytes[3] = (uint8_t)(x >> 8);
        bytes[4] = (uint8_t)(x & 0xff);
        bytes[5] = (uint8_t)(y >> 8);
        bytes[6] = (uint8_t)(y & 0xff);
        [encoded addObject:[NSData dataWithBytes:bytes length:sizeof(bytes)]];
    }

    if (encoded.count == 0) return;

    NSMutableData *payload = [NSMutableData dataWithCapacity:1 + encoded.count * 7];
    uint8_t count = (uint8_t)encoded.count;
    [payload appendBytes:&count length:1];
    for (NSData *entry in encoded) {
        [payload appendData:entry];
    }

    [self.receiver sendPacketType:PD_PACKET_TOUCH_V2 payload:payload];

    if (phase == PD_TOUCH_UP || phase == PD_TOUCH_CANCEL) {
        for (UITouch *touch in touches) {
            [self.touchIDs removeObjectForKey:[self keyForTouch:touch]];
        }
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self sendTouches:touches phase:PD_TOUCH_DOWN];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self sendTouches:touches phase:PD_TOUCH_MOVE];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self sendTouches:touches phase:PD_TOUCH_UP];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self sendTouches:touches phase:PD_TOUCH_CANCEL];
}

@end
