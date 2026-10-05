#import "DisplayViewController.h"
#import "PDStreamReceiver.h"
#import "PDH264Parser.h"
#import "PDVideoDecoder.h"
#import <AVFoundation/AVFoundation.h>

static const uint8_t PD_PACKET_TOUCH = 0x10;
static const uint8_t PD_TOUCH_DOWN = 0;
static const uint8_t PD_TOUCH_MOVE = 1;
static const uint8_t PD_TOUCH_UP = 2;
static const uint8_t PD_TOUCH_CANCEL = 3;

@interface DisplayViewController () <PDStreamReceiverDelegate, PDH264ParserDelegate, PDVideoDecoderDelegate>
@property(nonatomic,strong) AVSampleBufferDisplayLayer *displayLayer;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) PDStreamReceiver *receiver;
@property(nonatomic,strong) PDH264Parser *parser;
@property(nonatomic,strong) PDVideoDecoder *decoder;
@property(nonatomic) BOOL videoReady;
@end

@implementation DisplayViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;

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
    self.videoReady = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Connected - waiting for H.264";
    });
}

- (void)streamReceiverDidDisconnect:(PDStreamReceiver *)receiver error:(NSError *)error
{
    self.videoReady = NO;
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
        // Do not flash routine decoder/frame diagnostics over a working display.
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.hidden = NO;
        self.statusLabel.text = [NSString stringWithFormat:@"PadDisplay\n%@", status];
    });
}

- (void)sendTouch:(UITouch *)touch phase:(uint8_t)phase
{
    if (!self.receiver || self.view.bounds.size.width <= 0 || self.view.bounds.size.height <= 0) return;

    CGPoint point = [touch locationInView:self.view];
    CGFloat nx = MIN(1.0, MAX(0.0, point.x / self.view.bounds.size.width));
    CGFloat ny = MIN(1.0, MAX(0.0, point.y / self.view.bounds.size.height));

    uint16_t x = (uint16_t)lrint(nx * 65535.0);
    uint16_t y = (uint16_t)lrint(ny * 65535.0);

    uint8_t bytes[5];
    bytes[0] = phase;
    bytes[1] = (uint8_t)(x >> 8);
    bytes[2] = (uint8_t)(x & 0xff);
    bytes[3] = (uint8_t)(y >> 8);
    bytes[4] = (uint8_t)(y & 0xff);

    NSData *payload = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    [self.receiver sendPacketType:PD_PACKET_TOUCH payload:payload];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch) [self sendTouch:touch phase:PD_TOUCH_DOWN];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch) [self sendTouch:touch phase:PD_TOUCH_MOVE];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch) [self sendTouch:touch phase:PD_TOUCH_UP];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch) [self sendTouch:touch phase:PD_TOUCH_CANCEL];
}

@end
