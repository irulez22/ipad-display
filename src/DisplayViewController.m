#import "DisplayViewController.h"
#import "PDStreamReceiver.h"
#import "PDH264Parser.h"
#import "PDVideoDecoder.h"
#import <AVFoundation/AVFoundation.h>
@interface DisplayViewController () <PDStreamReceiverDelegate, PDH264ParserDelegate>
@property(nonatomic,strong) AVSampleBufferDisplayLayer *displayLayer; @property(nonatomic,strong) UILabel *statusLabel; @property(nonatomic,strong) PDStreamReceiver *receiver; @property(nonatomic,strong) PDH264Parser *parser; @property(nonatomic,strong) PDVideoDecoder *decoder;
@end
@implementation DisplayViewController
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor=[UIColor blackColor]; self.displayLayer=[[AVSampleBufferDisplayLayer alloc] init]; self.displayLayer.videoGravity=AVLayerVideoGravityResizeAspect; [self.view.layer addSublayer:self.displayLayer]; self.statusLabel=[[UILabel alloc] initWithFrame:CGRectZero]; self.statusLabel.textColor=[UIColor whiteColor]; self.statusLabel.textAlignment=NSTextAlignmentCenter; self.statusLabel.numberOfLines=0; self.statusLabel.text=@"PadDisplay\nWaiting for connection on TCP 4822"; [self.view addSubview:self.statusLabel]; self.decoder=[[PDVideoDecoder alloc] initWithDisplayLayer:self.displayLayer]; self.parser=[[PDH264Parser alloc] init]; self.parser.delegate=self; self.receiver=[[PDStreamReceiver alloc] initWithPort:4822]; self.receiver.delegate=self; [self.receiver start]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; self.displayLayer.frame=self.view.bounds; self.statusLabel.frame=CGRectInset(self.view.bounds,40,40); }
- (BOOL)prefersStatusBarHidden{return YES;} - (UIInterfaceOrientationMask)supportedInterfaceOrientations{return UIInterfaceOrientationMaskLandscape;}
- (void)streamReceiverDidConnect:(PDStreamReceiver *)r { dispatch_async(dispatch_get_main_queue(), ^{self.statusLabel.hidden=NO; self.statusLabel.text=@"Connected - waiting for H.264";}); }
- (void)streamReceiverDidDisconnect:(PDStreamReceiver *)r error:(NSError *)e { [self.parser flush]; [self.decoder reset]; dispatch_async(dispatch_get_main_queue(), ^{self.statusLabel.hidden=NO; self.statusLabel.text=@"Disconnected - waiting for connection";}); }
- (void)streamReceiver:(PDStreamReceiver *)r didReceivePacketType:(uint8_t)t payload:(NSData *)p { if(t==0x01)[self.parser appendData:p]; else if(t==0x04){[self.parser flush];[r disconnectClient];} }
- (void)h264Parser:(PDH264Parser *)p didOutputNALUnit:(NSData *)n type:(uint8_t)t { [self.decoder decodeNALUnit:n type:t]; if(t==5) dispatch_async(dispatch_get_main_queue(), ^{self.statusLabel.hidden=YES;}); }
@end
