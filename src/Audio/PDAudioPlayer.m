#import "PDAudioPlayer.h"
#import "PDLog.h"
#import <AudioToolbox/AudioToolbox.h>

@interface PDAudioPlayer ()
@property(nonatomic) AudioQueueRef queue;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger packetCount;
@property(nonatomic) NSUInteger queuedBuffers;
@property(nonatomic) NSUInteger targetPrebuffer;
@property(nonatomic) NSUInteger underrunCount;
@property(nonatomic) BOOL haveSequence;
@property(nonatomic) uint32_t lastSequence;
@property(nonatomic) uint64_t lastTimestampUS;
@end

static const NSUInteger PD_AUDIO_PREBUFFER_MIN = 6;   // ~120 ms
static const NSUInteger PD_AUDIO_PREBUFFER_MAX = 12;  // ~240 ms

static void PDAudioQueueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    PDAudioPlayer *player = (__bridge PDAudioPlayer *)userData;
    @synchronized (player) {
        if (player.queuedBuffers > 0) player.queuedBuffers--;
        if (player.started && player.queuedBuffers == 0) {
            player.started = NO;
            player.underrunCount++;
            if (player.targetPrebuffer < PD_AUDIO_PREBUFFER_MAX) {
                player.targetPrebuffer = MIN(PD_AUDIO_PREBUFFER_MAX, player.targetPrebuffer + 2);
            }
            PDLog(@"Audio underrun #%lu; adaptive prebuffer=%lu packets",
                  (unsigned long)player.underrunCount,
                  (unsigned long)player.targetPrebuffer);
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
    self.targetPrebuffer = PD_AUDIO_PREBUFFER_MIN;
    self.underrunCount = 0;
    self.haveSequence = NO;
    self.lastSequence = 0;
    self.lastTimestampUS = 0;
    PDLog(@"Audio ready PCM 48000Hz stereo s16le; adaptive prebuffer=%lu-%lu packets",
          (unsigned long)PD_AUDIO_PREBUFFER_MIN,
          (unsigned long)PD_AUDIO_PREBUFFER_MAX);
}

- (void)enqueuePCM:(NSData *)data
{
    [self enqueuePCM:data sequence:0 timestampUS:0];
}

- (void)enqueuePCM:(NSData *)data sequence:(uint32_t)sequence timestampUS:(uint64_t)timestampUS
{
    if (!data.length || data.length % 4 != 0) return;
    [self ensureQueue];
    if (!self.queue) return;

    @synchronized (self) {
        if (sequence != 0 || timestampUS != 0) {
            if (self.haveSequence) {
                uint32_t expected = self.lastSequence + 1;
                if (sequence != expected) {
                    PDLog(@"Audio sequence gap expected=%u got=%u delta=%u",
                          expected, sequence, (unsigned)(sequence - expected));
                }
                if (timestampUS && self.lastTimestampUS && timestampUS <= self.lastTimestampUS) {
                    PDLog(@"Audio timestamp non-monotonic previous=%llu current=%llu",
                          self.lastTimestampUS, timestampUS);
                }
            }
            self.haveSequence = YES;
            self.lastSequence = sequence;
            self.lastTimestampUS = timestampUS;
        }
    }

    AudioQueueBufferRef buffer = NULL;
    OSStatus s = AudioQueueAllocateBuffer(self.queue, (UInt32)data.length, &buffer);
    if (s != noErr || !buffer) {
        PDLog(@"AudioQueueAllocateBuffer failed status=%d", (int)s);
        return;
    }

    memcpy(buffer->mAudioData, data.bytes, data.length);
    buffer->mAudioDataByteSize = (UInt32)data.length;
    @synchronized (self) { self.queuedBuffers++; }
    s = AudioQueueEnqueueBuffer(self.queue, buffer, 0, NULL);
    if (s != noErr) {
        PDLog(@"AudioQueueEnqueueBuffer failed status=%d", (int)s);
        @synchronized (self) { self.queuedBuffers--; }
        AudioQueueFreeBuffer(self.queue, buffer);
        return;
    }

    @synchronized (self) {
        self.packetCount++;

        if (!self.started && self.queuedBuffers >= self.targetPrebuffer) {
            s = AudioQueueStart(self.queue, NULL);
            if (s == noErr) {
                self.started = YES;
                PDLog(@"Audio playback started buffered=%lu target=%lu underruns=%lu",
                      (unsigned long)self.queuedBuffers,
                      (unsigned long)self.targetPrebuffer,
                      (unsigned long)self.underrunCount);
            } else {
                PDLog(@"AudioQueueStart failed status=%d", (int)s);
            }
        } else if (self.packetCount % 500 == 0) {
            PDLog(@"Audio packets=%lu queued=%lu target=%lu underruns=%lu seq=%u",
                  (unsigned long)self.packetCount,
                  (unsigned long)self.queuedBuffers,
                  (unsigned long)self.targetPrebuffer,
                  (unsigned long)self.underrunCount,
                  self.lastSequence);
        }

        // Slowly return toward the low-latency target after a long stable run.
        if (self.started && self.packetCount > 0 && self.packetCount % 1500 == 0 &&
            self.targetPrebuffer > PD_AUDIO_PREBUFFER_MIN) {
            self.targetPrebuffer--;
            PDLog(@"Audio stable; reducing adaptive prebuffer to %lu packets",
                  (unsigned long)self.targetPrebuffer);
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
    self.targetPrebuffer = PD_AUDIO_PREBUFFER_MIN;
    self.underrunCount = 0;
    self.haveSequence = NO;
    self.lastSequence = 0;
    self.lastTimestampUS = 0;

    PDLog(@"Audio reset");
}

- (void)dealloc
{
    [self reset];
}

@end
