//
//  SSAudioStreamer.m
//  SSAudioToolBox
//
//  Created by king on 2017/8/7.
//  Copyright © 2017年 king. All rights reserved.
//

#import "SSAudioStreamer.h"
#import "SSAudioEngineUtility.h"
#import "SSAudioFile.h"
#import "SSAudioDataProvider.h"
#import "SSAudioEngineRenderer.h"
#import "SSAudioQueueRenderer.h"
#import "SSAudioDecoder.h"
#import "SSAudioLocalDataProvider.h"
#import "SSAudioRemoteDataProvider.h"
#import "SSAudioEngineCommon.h"
#import "SSAudioFFmpegDecoder.h"
#import "SSAudioFileStreamDecoder.h"
#import "SSAudioDecoderPool.h"
#import "SSAudioFrame.h"

@interface SSAudioStreamer ()<SSAudioEngineRendererDelegate,SSAudioDecoderPoolDelegate,SSAudioDecoderDelegate,SSAudioDataProviderDelegate,SSAudioQueueRendererDatasource>
@property (nonatomic, strong) SSAudioEngineRenderer *renderer;
@property (nonatomic, strong) id<SSAudioFile> audioFile;
@property (nonatomic, strong) id<SSAudioDecoder> decode;
@property (nonatomic, strong) id<SSAudioDataProvider> provider;
@property (nonatomic, strong) SSAudioDecoderPool *decoderPool;
@property (nonatomic, assign) BOOL hasBeginDecode;
@property (nonatomic, assign) BOOL hasPlay;
@property (nonatomic, strong) SSAudioFrame *currentAudioFrame;
@end

@implementation SSAudioStreamer
- (instancetype)initWithAudioFile:(id<SSAudioFile>)file {
    if (self == [super init]) {
        self.audioFile = file;
        self.hasBeginDecode = NO;
    }
    return self;
}


- (void)prepare {
    
    self.decoderPool = [[SSAudioDecoderPool alloc] init];
    self.decoderPool.delegaet = self;
    self.decoderPool.minBufferSize = decode_pool_min_buffer_size;
    self.decoderPool.maxBufferSize = decode_pool_max_buffer_size;
    if ([[self.audioFile ss_audioURL] isFileURL]) {
        self.provider = [SSAudioLocalDataProvider dataProviderWithAudioFile:self.audioFile];
    } else {
        self.provider = [SSAudioRemoteDataProvider dataProviderWithAudioFile:self.audioFile];
    }
    self.provider.delegate = self;
    
    
//    self.decode = [[SSAudioFFmpegDecoder alloc] initWithDataProvider:self.provider];
//    self.decode.delegate = self;
//    self.hasBeginDecode = NO;
    
    BOOL b = NO;
    if (b) {
        self.decode = [[SSAudioFileStreamDecoder alloc] initWithDataProvider:self.provider];
    } else {
        self.decode = [[SSAudioFFmpegDecoder alloc] initWithDataProvider:self.provider];
    }
    self.decode.delegate = self;
//    [self.decode startDecode];
    
    self.renderer = [[SSAudioEngineRenderer alloc] initWithUseAudioFileStream:b];
    self.renderer.delegate = self;
    [self.provider prepare];

}
#pragma mark - SSAudioDataProviderDelegate
- (void)audioDataProviderDidPrepare:(id<SSAudioDataProvider>)audioDataProvider {
    @synchronized(self) {
        if (self.hasBeginDecode) {
            return;
        }
        self.hasBeginDecode = YES;
        [self.decode startDecode];
    }
}
#pragma mark - SSAudioDecoderPoolDelegate
/**第一次有足够的解码缓存可以开始启动播放队列了*/
- (void)hasEnoughBufferToPlay {
    @synchronized (self) {
        if (self.hasPlay) {
            return;
        }
        [self.renderer start];
        self.hasPlay = YES;
    }
}
/**解码缓存区数据不够,等待更多多数据进入*/
- (void)waitingForMoreDecodeBuffer {
    @synchronized (self) {
        if (self.hasPlay == NO) {
            return;
        }
        [self.renderer pause];
        self.hasPlay = NO;
    }
}
/**解码缓存区数据已经达到最小缓存大小*/
- (void)hasEnoughDecodeBuffer {
    @synchronized (self) {
        if (self.hasPlay) {
            return;
        }
        [self.renderer start];
        self.hasPlay = YES;
    }
}

#pragma mark - SSAudioDataProviderDelegate
- (void)audioDataProviderDelegate:(id<SSAudioDataProvider>)provider didReadData:(NSData *)data {
   
    
}
#pragma mark - SSAudioDecoderDelegate
- (void)audioDecoderDidDecodeHeaderComplete:(id<SSAudioDecoder>)decoder {
    NSLog(@"头部解析完成");
    
//    AudioStreamBasicDescription asbd = decoder.streamBasicDescription;
//    [self.renderer cretaeAudioConverterWithAudioStreamDescription:&asbd];
}
- (void)audioDecoder:(id<SSAudioDecoder>)decoder didDecodeFrame:(SSAudioFrame *)frame {
    @synchronized (self) {
        [self.decoderPool pushDecodedData:frame];
    }
}
#pragma mark - SSAudioEngineRendererDelegate
- (void)audioEngineRendererNeedFrameData:(SSAudioEngineRenderer *)renderer
                              outputData:(float *)outputData
                          numberOfFrames:(UInt32)numberOfFrames
                        numberOfChannels:(UInt32)numberOfChannels {
    @autoreleasepool {
    
        while (numberOfFrames > 0) {
            
            if (!self.currentAudioFrame) {
                self.currentAudioFrame = [self.decoderPool popDecodeData];
            }
            if (!self.currentAudioFrame) {
                memset(outputData, 0, numberOfFrames * numberOfChannels * sizeof(float));
                return;
            }
            
            const Byte * bytes = (Byte *)self.currentAudioFrame->data + self.currentAudioFrame->output_offset;
            const NSUInteger bytesLeft = self.currentAudioFrame->length - self.currentAudioFrame->output_offset;
            const NSUInteger frameSizeOf = numberOfChannels * sizeof(float);
            const NSUInteger bytesToCopy = MIN(numberOfFrames * frameSizeOf, bytesLeft);
            const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;
            
            memcpy(outputData, bytes, bytesToCopy);
            numberOfFrames -= framesToCopy;
            outputData += framesToCopy * numberOfChannels;
            
            if (bytesToCopy < bytesLeft) {
                self.currentAudioFrame->output_offset += bytesToCopy;
            } else {
                self.currentAudioFrame = nil;
            }
            
        }
    
    }
}
- (SSAudioFrame *)audioEngineRendererNeedFrameData:(SSAudioEngineRenderer *)renderer {
    
    return [self.decoderPool popDecodeData];
}

- (void)audioQueueRenderer:(SSAudioQueueRenderer *)renderer
                    buffer:(void *)buffer
                  needSize:(UInt32)needSize
                  realSize:(UInt32 *)realSize {
    
    @autoreleasepool {
        while (needSize > 0) {
            if (!self.currentAudioFrame) {
                self.currentAudioFrame = [self.decoderPool popDecodeData];
            }
            
            if (!self.currentAudioFrame) {
                return;
            }
            
            const Byte * bytes = (Byte *)self.currentAudioFrame->data + self.currentAudioFrame->output_offset;
            const NSUInteger bytesLeft = self.currentAudioFrame->length - self.currentAudioFrame->output_offset;
            const NSUInteger bytesToCopy = MIN(needSize, bytesLeft);
            memcpy(buffer, bytes, bytesToCopy);
            needSize -= bytesToCopy;
            *realSize += bytesToCopy;
            if (bytesToCopy < bytesLeft) {
                self.currentAudioFrame->output_offset += bytesToCopy;
            } else {
                self.currentAudioFrame = nil;
            }
        }
    }
}
@end

