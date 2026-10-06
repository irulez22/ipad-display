#import "PDAudioPlayer.h"
#import "PDLog.h"
#import <AudioToolbox/AudioToolbox.h>

@interface PDAudioPlayer ()
@property(nonatomic) AudioQueueRef queue;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger packetCount;
@property(nonatomic) NSUInteger queuedBuffers;
@end

static const NSUInteger PD_AUDIO_PREBUFFER_COUNT = 6; // ~120 ms at 20 ms/packet

static void PDAudioQueueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    PDAudioPlayer *player = (__bridge PDAudioPlayer *)userData;
    @synchronized (player) {
        if (player.queuedBuffers > 0) player.queuedBuffers--;
        if (player.started && player.queuedBuffers == 0) {
            player.started = NO;
            PDLog(@"Audio underrun; rebuffering");
        }
    }
    if (buffer) AudioQueueFreeBuffer(queue, buffer);
}

@implementation PDAudioPlayer

- (void)ensureQueue
{
    if (self.queue) return;

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = 48000.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    fmt.mBytesPerPacket = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 4;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 16;

    OSStatus s = AudioQueueNewOutput(&fmt, PDAudioQueueCallback, (__bridge void *)self,
                                     NULL, NULL, 0, &_queue);
    if (s != noErr || !self.queue) {
        PDLog(@"AudioQueue create failed status=%d", (int)s);
        self.queue = NULL;
        return;
    }

    self.started = NO;
    self.packetCount = 0;
    self.queuedBuffers = 0;
    PDLog(@"Audio ready PCM 48000Hz stereo s16le; prebuffer=%lu packets",
          (unsigned long)PD_AUDIO_PREBUFFER_COUNT);
}

- (void)enqueuePCM:(NSData *)data
{
    if (!data.length) return;
    [self ensureQueue];
    if (!self.queue) return;

    AudioQueueBufferRef buffer = NULL;
    OSStatus s = AudioQueueAllocateBuffer(self.queue, (UInt32)data.length, &buffer);
    if (s != noErr || !buffer) {
        PDLog(@"AudioQueueAllocateBuffer failed status=%d", (int)s);
        return;
    }

    memcpy(buffer->mAudioData, data.bytes, data.length);
    buffer->mAudioDataByteSize = (UInt32)data.length;
    s = AudioQueueEnqueueBuffer(self.queue, buffer, 0, NULL);
    if (s != noErr) {
        PDLog(@"AudioQueueEnqueueBuffer failed status=%d", (int)s);
        AudioQueueFreeBuffer(self.queue, buffer);
        return;
    }

    @synchronized (self) {
        self.packetCount++;
        self.queuedBuffers++;

        if (!self.started && self.queuedBuffers >= PD_AUDIO_PREBUFFER_COUNT) {
            s = AudioQueueStart(self.queue, NULL);
            if (s == noErr) {
                self.started = YES;
                PDLog(@"Audio playback started buffered=%lu",
                      (unsigned long)self.queuedBuffers);
            } else {
                PDLog(@"AudioQueueStart failed status=%d", (int)s);
            }
        } else if (self.packetCount % 500 == 0) {
            PDLog(@"Audio packets=%lu queued=%lu",
                  (unsigned long)self.packetCount,
                  (unsigned long)self.queuedBuffers);
        }
    }
}

- (void)reset
{
    if (self.queue) {
        AudioQueueStop(self.queue, true);
        AudioQueueDispose(self.queue, true);
        self.queue = NULL;
    }
    self.started = NO;
    self.packetCount = 0;
    self.queuedBuffers = 0;

    PDLog(@"Audio reset");
}

- (void)dealloc
{
    [self reset];
}

@end
