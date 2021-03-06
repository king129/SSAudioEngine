//
//  SSAudioEngineRenderer.m
//  SSAudioToolBox
//
//  Created by king on 2017/8/25.
//  Copyright © 2017年 king. All rights reserved.
//

#import "SSAudioEngineRenderer.h"
#import "SSAudioEngineUtility.h"
#import "SSAudioFrame.h"
#import "SSAudioEngineCommon.h"
#import <Accelerate/Accelerate.h>

#if SSPLATFORM_TARGET_OS_MAC
#import "SSMacAudioSession.h"
#elif SSPLATFORM_TARGET_OS_IPHONE_OR_TV
#import "SSAudioSession.h"
#endif

static int const max_frame_size = 4096;
static int const max_chan = 2;

typedef struct
{
    AUNode node;
    AudioUnit audioUnit;
}
SSAudioNodeContext;

typedef struct
{
    AUGraph graph;
    SSAudioNodeContext converterNodeContext;
    SSAudioNodeContext mixerNodeContext;
    SSAudioNodeContext outputNodeContext;
    AudioStreamBasicDescription commonFormat;
}
SSAudioOutputContext;

static NSError * checkError(OSStatus result, NSString * domain)
{
    if (result == noErr) return nil;
    NSError * error = [NSError errorWithDomain:domain code:result userInfo:nil];
    return error;
}

@interface SSAudioEngineRenderer ()
{
    float *_outData;
}
@property (nonatomic, assign) SSAudioOutputContext *outputContext;
#if SSPLATFORM_TARGET_OS_MAC
@property (nonatomic, strong) SSMacAudioSession *audioSession;
#elif SSPLATFORM_TARGET_OS_IPHONE_OR_TV
@property (nonatomic, strong) SSAudioSession *audioSession;
#endif
@property (nonatomic, strong) NSError * error;
@property (nonatomic, strong) NSError * warning;
@property (nonatomic, assign) BOOL registered;
@end


@implementation SSAudioEngineRenderer
{
    AudioBufferList *renderBufferList;
    AudioConverterRef converter;
}
- (instancetype)initWithUseAudioFileStream:(BOOL)flag {
    if (self == [super init]) {
        _useAudioFileStream = flag;
        [self prepare];
    }
    return self;
}
- (void)prepare {
#if SSPLATFORM_TARGET_OS_MAC
    self.audioSession = [SSMacAudioSession sharedInstance];
#elif SSPLATFORM_TARGET_OS_IPHONE_OR_TV
    self.audioSession = [SSAudioSession sharedInstance];
#endif
    self->_outData = (float *)calloc(max_frame_size * max_chan, sizeof(float));
    
    if (_useAudioFileStream) {
        renderBufferList = (AudioBufferList *)calloc(1, sizeof(UInt32) + sizeof(AudioBuffer));
        renderBufferList->mNumberBuffers = 1;
        renderBufferList->mBuffers[0].mNumberChannels = 2;
        renderBufferList->mBuffers[0].mDataByteSize = kRenderBufferSize;
        renderBufferList->mBuffers[0].mData = calloc(1, kRenderBufferSize);
    }
}
- (BOOL)cretaeAudioConverterWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription {
    if (audioStreamBasicDescription == NULL) {
        return NO;
    }
    AudioStreamBasicDescription destFormat = SSSignedIntLinearPCMStreamDescription();
    OSStatus status = AudioConverterNew(&(*audioStreamBasicDescription), &destFormat, &converter);
    
    return (status == noErr && converter != NULL);
}
- (BOOL)registerAudioSession
{
    if (!self.registered) {
        if ([self setupAudioUnit]) {
            self.registered = YES;
        }
    }
#if SSPLATFORM_TARGET_OS_MAC
#elif SSPLATFORM_TARGET_OS_IPHONE_OR_TV
    [self.audioSession setCategory:AVAudioSessionCategoryPlayback error:nil];
    [self.audioSession setActive:YES error:nil];
#endif
    return self.registered;
}

- (void)unregisterAudioSession
{
    if (self.registered) {
        self.registered = NO;
        OSStatus result = AUGraphUninitialize(self.outputContext->graph);
        self.warning = checkError(result, @"graph uninitialize error");
        if (self.warning) {
            [self delegateWarningCallback];
        }
        result = AUGraphClose(self.outputContext->graph);
        self.warning = checkError(result, @"graph close error");
        if (self.warning) {
            [self delegateWarningCallback];
        }
        result = DisposeAUGraph(self.outputContext->graph);
        self.warning = checkError(result, @"graph dispose error");
        if (self.warning) {
            [self delegateWarningCallback];
        }
        if (self.outputContext) {
            free(self.outputContext);
            self.outputContext = NULL;
        }
    }
}

- (BOOL)setupAudioUnit
{
    
    OSStatus result;
    UInt32 audioStreamBasicDescriptionSize = sizeof(AudioStreamBasicDescription);
    self.outputContext = (SSAudioOutputContext *)malloc(sizeof(SSAudioOutputContext));
    memset(self.outputContext, 0, sizeof(SSAudioOutputContext));
    
    result = NewAUGraph(&self.outputContext->graph);
    self.error = checkError(result, @"create  graph error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    AudioComponentDescription converterDescription;
    converterDescription.componentType = kAudioUnitType_FormatConverter;
    converterDescription.componentSubType = kAudioUnitSubType_AUConverter;
    converterDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    result = AUGraphAddNode(self.outputContext->graph, &converterDescription, &self.outputContext->converterNodeContext.node);
    self.error = checkError(result, @"graph add converter node error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    AudioComponentDescription mixerDescription;
    mixerDescription.componentType = kAudioUnitType_Mixer;
#if SSPLATFORM_TARGET_OS_MAC
    mixerDescription.componentSubType = kAudioUnitSubType_StereoMixer;
#elif SSPLATFORM_TARGET_OS_IPHONE_OR_TV
    mixerDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer;
#endif
    mixerDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    result = AUGraphAddNode(self.outputContext->graph, &mixerDescription, &self.outputContext->mixerNodeContext.node);
    self.error = checkError(result, @"graph add mixer node error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    AudioComponentDescription outputDescription;
    outputDescription.componentType = kAudioUnitType_Output;
#if SSPLATFORM_TARGET_OS_MAC
    outputDescription.componentSubType = kAudioUnitSubType_DefaultOutput;
#elif SSPLATFORM_TARGET_OS_IPHONE_OR_TV
    outputDescription.componentSubType = kAudioUnitSubType_RemoteIO;
#endif
    outputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    result = AUGraphAddNode(self.outputContext->graph, &outputDescription, &self.outputContext->outputNodeContext.node);
    self.error = checkError(result, @"graph add output node error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AUGraphOpen(self.outputContext->graph);
    self.error = checkError(result, @"open graph error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AUGraphConnectNodeInput(self.outputContext->graph,
                                     self.outputContext->converterNodeContext.node,
                                     0,
                                     self.outputContext->mixerNodeContext.node,
                                     0);
    self.error = checkError(result, @"graph connect converter and mixer error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AUGraphConnectNodeInput(self.outputContext->graph,
                                     self.outputContext->mixerNodeContext.node,
                                     0,
                                     self.outputContext->outputNodeContext.node,
                                     0);
    self.error = checkError(result, @"graph connect converter and mixer error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AUGraphNodeInfo(self.outputContext->graph,
                             self.outputContext->converterNodeContext.node,
                             &converterDescription,
                             &self.outputContext->converterNodeContext.audioUnit);
    self.error = checkError(result, @"graph get converter audio unit error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AUGraphNodeInfo(self.outputContext->graph,
                             self.outputContext->mixerNodeContext.node,
                             &mixerDescription,
                             &self.outputContext->mixerNodeContext.audioUnit);
    self.error = checkError(result, @"graph get minxer audio unit error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AUGraphNodeInfo(self.outputContext->graph,
                             self.outputContext->outputNodeContext.node,
                             &outputDescription,
                             &self.outputContext->outputNodeContext.audioUnit);
    self.error = checkError(result, @"graph get output audio unit error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    AURenderCallbackStruct converterCallback;
    converterCallback.inputProc = renderCallback;
    converterCallback.inputProcRefCon = (__bridge void *)(self);
    result = AUGraphSetNodeInputCallback(self.outputContext->graph,
                                         self.outputContext->converterNodeContext.node,
                                         0,
                                         &converterCallback);
    self.error = checkError(result, @"graph add converter input callback error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AudioUnitGetProperty(self.outputContext->outputNodeContext.audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0,
                                  &self.outputContext->commonFormat,
                                  &audioStreamBasicDescriptionSize);
    self.warning = checkError(result, @"get hardware output stream format error");
    if (self.warning) {
        [self delegateWarningCallback];
    } else {
        if (self.audioSession.sampleRate != self.outputContext->commonFormat.mSampleRate) {
            self.outputContext->commonFormat.mSampleRate = self.audioSession.sampleRate;
            result = AudioUnitSetProperty(self.outputContext->outputNodeContext.audioUnit,
                                          kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input,
                                          0,
                                          &self.outputContext->commonFormat,
                                          audioStreamBasicDescriptionSize);
            self.warning = checkError(result, @"set hardware output stream format error");
            if (self.warning) {
                [self delegateWarningCallback];
            }
        }
    }
    
    result = AudioUnitSetProperty(self.outputContext->converterNodeContext.audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &self.outputContext->commonFormat,
                                  audioStreamBasicDescriptionSize);
    self.error = checkError(result, @"graph set converter input format error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AudioUnitSetProperty(self.outputContext->converterNodeContext.audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  0,
                                  &self.outputContext->commonFormat,
                                  audioStreamBasicDescriptionSize);
    self.error = checkError(result, @"graph set converter output format error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AudioUnitSetProperty(self.outputContext->mixerNodeContext.audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &self.outputContext->commonFormat,
                                  audioStreamBasicDescriptionSize);
    self.error = checkError(result, @"graph set converter input format error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AudioUnitSetProperty(self.outputContext->mixerNodeContext.audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  0,
                                  &self.outputContext->commonFormat,
                                  audioStreamBasicDescriptionSize);
    self.error = checkError(result, @"graph set converter output format error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    result = AudioUnitSetProperty(self.outputContext->mixerNodeContext.audioUnit,
                                  kAudioUnitProperty_MaximumFramesPerSlice,
                                  kAudioUnitScope_Global,
                                  0,
                                  &max_frame_size,
                                  sizeof(max_frame_size));
    self.warning = checkError(result, @"graph set mixer max frames per slice size error");
    if (self.warning) {
        [self delegateWarningCallback];
    }
    
    result = AUGraphInitialize(self.outputContext->graph);
    self.error = checkError(result, @"graph initialize error");
    if (self.error) {
        [self delegateErrorCallback];
        return NO;
    }
    
    return YES;
}

- (Float64)samplingRate
{
    if (!self.registered) {
        return 0;
    }
    Float64 number = self.outputContext->commonFormat.mSampleRate;
    if (number > 0) {
        return number;
    }
    return (Float64)self.audioSession.sampleRate;
}

- (UInt32)numberOfChannels
{
    if (!self.registered) {
        return 0;
    }
    UInt32 number = self.outputContext->commonFormat.mChannelsPerFrame;
    if (number > 0) {
        return number;
    }
    return (UInt32)self.audioSession.outputNumberOfChannels;
}

- (void)start
{
    
    if (!self->_playing) {
        if ([self registerAudioSession]) {
            OSStatus result = AUGraphStart(self.outputContext->graph);
            self.error = checkError(result, @"graph start error");
            if (self.error) {
                [self delegateErrorCallback];
            } else {
                self->_playing = YES;
            }
        }
    }
    
}

- (void)pause
{
    
    if (self->_playing) {
        OSStatus result = AUGraphStop(self.outputContext->graph);
        self.error = checkError(result, @"graph stop error");
        if (self.error) {
            [self delegateErrorCallback];
        }
        self->_playing = NO;
    }
    
}
- (void)delegateErrorCallback
{
    if (self.error) {
        NSLog(@"SSAudioManager did error : %@", self.error);
    }
}

- (void)delegateWarningCallback
{
    if (self.warning) {
        NSLog(@"SSAudioManager did warning : %@", self.warning);
    }
}

- (OSStatus)renderFrames:(UInt32)numberOfFrames ioData:(AudioBufferList *)ioData {
    
    if (!self.registered) {
        return noErr;
    }
    for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; iBuffer++) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    [self.delegate audioEngineRendererNeedFrameData:self
                                         outputData:self->_outData
                                     numberOfFrames:numberOfFrames
                                   numberOfChannels:self.numberOfChannels];
    
    UInt32 numBytesPerSample = self.outputContext->commonFormat.mBitsPerChannel / 8;
    if (numBytesPerSample == 4) {
        float zero = 0.0;
        for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; iBuffer++) {
            int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
            for (int iChannel = 0; iChannel < thisNumChannels; iChannel++) {
                vDSP_vsadd(self->_outData + iChannel,
                           self.numberOfChannels,
                           &zero,
                           (float *)ioData->mBuffers[iBuffer].mData,
                           thisNumChannels,
                           numberOfFrames);
            }
        }
    }
    else if (numBytesPerSample == 2)
    {
        float scale = (float)INT16_MAX;
        vDSP_vsmul(self->_outData, 1, &scale, self->_outData, 1, numberOfFrames * self.numberOfChannels);
        
        for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; iBuffer++) {
            int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
            for (int iChannel = 0; iChannel < thisNumChannels; iChannel++) {
                vDSP_vfix16(self->_outData + iChannel,
                            self.numberOfChannels,
                            (SInt16 *)ioData->mBuffers[iBuffer].mData + iChannel,
                            thisNumChannels,
                            numberOfFrames);
            }
        }
    }
    return noErr;
}
- (OSStatus)renderFramesWithUseAudioFileStream:(UInt32)numberOfFrames ioData:(AudioBufferList *)ioData {
    
    if (!self.registered && converter != NULL) {
        return noErr;
    }
    for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; iBuffer++) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    @autoreleasepool {
        UInt32 packetSize = numberOfFrames;
        OSStatus status = AudioConverterFillComplexBuffer(converter,
                                                          SSPlayerConverterFiller,
                                                          (__bridge void *)(self),
                                                          &packetSize,
                                                          renderBufferList,
                                                          NULL);
        if (status != noErr && status != SSAudioConverterCallbackErr_NoData) {
            [self pause];
            return -1;
        } else if (!packetSize) {
            ioData->mNumberBuffers = 0;
        } else {
            ioData->mNumberBuffers = 1;
            ioData->mBuffers[0].mNumberChannels = 2;
            ioData->mBuffers[0].mDataByteSize = renderBufferList->mBuffers[0].mDataByteSize;
            ioData->mBuffers[0].mData = renderBufferList->mBuffers[0].mData;
            renderBufferList->mBuffers[0].mDataByteSize = kRenderBufferSize;
        }
    }
    
    return noErr;
}
static OSStatus renderCallback(void * inRefCon,
                               AudioUnitRenderActionFlags * ioActionFlags,
                               const AudioTimeStamp * inTimeStamp,
                               UInt32 inOutputBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList * ioData)
{
    SSAudioEngineRenderer * manager = (__bridge SSAudioEngineRenderer *)inRefCon;
    if (manager.useAudioFileStream) {
        return [manager renderFramesWithUseAudioFileStream:inNumberFrames ioData:ioData];
    } else {
        return [manager renderFrames:inNumberFrames ioData:ioData];
    }
}

static OSStatus SSPlayerConverterFiller(AudioConverterRef inAudioConverter,
                                        UInt32* ioNumberDataPackets,
                                        AudioBufferList* ioData,
                                        AudioStreamPacketDescription** outDataPacketDescription,
                                        void* inUserData) {
    static AudioStreamPacketDescription aspdesc;
    @autoreleasepool {
        SSAudioEngineRenderer *self = (__bridge SSAudioEngineRenderer *)inUserData;
        SSAudioFrame *frame = [self.delegate audioEngineRendererNeedFrameData:self];
        if (!frame) {
            return SSAudioConverterCallbackErr_NoData;
        }
        
        ioData->mNumberBuffers = 1;
        if (ioData->mBuffers[0].mData == NULL) {
            ioData->mBuffers[0].mData = malloc(frame->length);
        }
        memcpy(ioData->mBuffers[0].mData, frame->data, frame->length);
        ioData->mBuffers[0].mDataByteSize = frame->length;
        *outDataPacketDescription = &aspdesc;
        aspdesc.mDataByteSize = frame->length;
        aspdesc.mStartOffset = 0;
        aspdesc.mVariableFramesInPacket = 1;
        frame = nil;
    }
    
    
    return noErr;
}
@end

