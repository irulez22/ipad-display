#import "PDVideoDecoder.h"
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

@interface PDVideoDecoder ()
@property(nonatomic,weak) AVSampleBufferDisplayLayer*displayLayer;
@property(nonatomic,strong) NSData*sps;
@property(nonatomic,strong) NSData*pps;
@property(nonatomic) CMVideoFormatDescriptionRef formatDescription;
@property(nonatomic) VTDecompressionSessionRef session;
@property(nonatomic) NSUInteger frameCount;
@property(nonatomic) NSUInteger errorCount;
@end

static void PDDecompressionCallback(void *refCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration);

@implementation PDVideoDecoder
- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer*)l{if((self=[super init]))_displayLayer=l;return self;}
- (void)dealloc{[self destroySession];if(_formatDescription)CFRelease(_formatDescription);}
- (void)report:(NSString*)s{id<PDVideoDecoderDelegate>d=self.delegate;if(d)[d videoDecoder:self didUpdateStatus:s];NSLog(@"PadDisplay decoder: %@",s);}
- (void)destroySession{if(self.session){VTDecompressionSessionInvalidate(self.session);CFRelease(self.session);self.session=NULL;}}
- (void)reset{[self destroySession];self.sps=nil;self.pps=nil;self.frameCount=0;self.errorCount=0;if(self.formatDescription){CFRelease(self.formatDescription);self.formatDescription=NULL;}dispatch_async(dispatch_get_main_queue(), ^{[self.displayLayer flushAndRemoveImage];});}
- (void)rebuild{
    if(!self.sps||!self.pps)return;
    [self destroySession];
    if(self.formatDescription){CFRelease(self.formatDescription);self.formatDescription=NULL;}
    const uint8_t*p[2]={self.sps.bytes,self.pps.bytes};const size_t z[2]={self.sps.length,self.pps.length};
    OSStatus s=CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,2,p,z,4,&_formatDescription);
    if(s!=noErr||!self.formatDescription){[self report:[NSString stringWithFormat:@"Format description error: %d",(int)s]];return;}
    VTDecompressionOutputCallbackRecord cb={PDDecompressionCallback,(__bridge void*)self};
    NSDictionary*attrs=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                         (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    s=VTDecompressionSessionCreate(kCFAllocatorDefault,self.formatDescription,NULL,(__bridge CFDictionaryRef)attrs,&cb,&_session);
    if(s==noErr&&self.session)[self report:@"Decoder ready (VideoToolbox)"];
    else [self report:[NSString stringWithFormat:@"VideoToolbox session error: %d",(int)s]];
}
- (void)decodeNALUnit:(NSData*)nal type:(uint8_t)t{
    if(!nal.length)return;
    if(t==7){self.sps=[nal copy];[self report:@"SPS received"];[self rebuild];return;}
    if(t==8){self.pps=[nal copy];[self report:@"PPS received"];[self rebuild];return;}
    if(t!=1&&t!=5)return;
    if(!self.session||!self.formatDescription)return;
    uint32_t n=CFSwapInt32HostToBig((uint32_t)nal.length);
    NSMutableData*d=[NSMutableData dataWithBytes:&n length:4];[d appendData:nal];
    CMBlockBufferRef b=NULL;OSStatus s=CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,NULL,d.length,kCFAllocatorDefault,NULL,0,d.length,0,&b);
    if(s!=kCMBlockBufferNoErr||!b){self.errorCount++;return;}
    s=CMBlockBufferReplaceDataBytes(d.bytes,b,0,d.length);
    if(s!=kCMBlockBufferNoErr){CFRelease(b);self.errorCount++;return;}
    size_t size=d.length;CMSampleBufferRef sample=NULL;
    s=CMSampleBufferCreateReady(kCFAllocatorDefault,b,self.formatDescription,1,0,NULL,1,&size,&sample);CFRelease(b);
    if(s!=noErr||!sample){self.errorCount++;return;}
    VTDecodeFrameFlags flags=kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags outFlags=0;
    s=VTDecompressionSessionDecodeFrame(self.session,sample,flags,NULL,&outFlags);
    CFRelease(sample);
    if(s!=noErr){self.errorCount++;[self report:[NSString stringWithFormat:@"Decode error %d (%lu total)",(int)s,(unsigned long)self.errorCount]];}
}
- (void)presentImageBuffer:(CVImageBufferRef)imageBuffer status:(OSStatus)status{
    if(status!=noErr||!imageBuffer){self.errorCount++;[self report:[NSString stringWithFormat:@"Frame error %d (%lu total)",(int)status,(unsigned long)self.errorCount]];return;}
    CFRetain(imageBuffer);
    self.frameCount++;
    if(self.frameCount==1||self.frameCount%120==0){
        size_t w=CVPixelBufferGetWidth(imageBuffer),h=CVPixelBufferGetHeight(imageBuffer);
        [self report:[NSString stringWithFormat:@"VideoToolbox OK - %lux%lu - frames %lu",(unsigned long)w,(unsigned long)h,(unsigned long)self.frameCount]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        CMVideoFormatDescriptionRef fd=NULL;CMSampleBufferRef sb=NULL;
        OSStatus e=CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,imageBuffer,&fd);
        if(e==noErr&&fd){
            CMSampleTimingInfo ti={kCMTimeInvalid,kCMTimeInvalid,kCMTimeInvalid};
            e=CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,imageBuffer,YES,NULL,NULL,fd,&ti,&sb);
        }
        if(e==noErr&&sb){
            CFArrayRef aa=CMSampleBufferGetSampleAttachmentsArray(sb,YES);
            if(aa&&CFArrayGetCount(aa)){CFMutableDictionaryRef a=(CFMutableDictionaryRef)CFArrayGetValueAtIndex(aa,0);CFDictionarySetValue(a,kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);}
            if(self.displayLayer.status==AVQueuedSampleBufferRenderingStatusFailed)[self.displayLayer flush];
            [self.displayLayer enqueueSampleBuffer:sb];
        }
        if(sb)CFRelease(sb);if(fd)CFRelease(fd);CFRelease(imageBuffer);
    });
}
@end

static void PDDecompressionCallback(void *refCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration){
    PDVideoDecoder*d=(__bridge PDVideoDecoder*)refCon;
    [d presentImageBuffer:imageBuffer status:status];
}
