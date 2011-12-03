//
//  PdAudioUnit.m
//  libpd
//
//  Created on 29/09/11.
//
//  For information on usage and redistribution, and for a DISCLAIMER OF ALL
//  WARRANTIES, see the file, "LICENSE.txt," in this distribution.
//

#import "PdAudioUnit.h"
#import "PdBase.h"
#import "AudioHelpers.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

static const AudioUnitElement kInputElement = 1;
static const AudioUnitElement kOutputElement = 0;

@interface PdAudioUnit ()

@property (nonatomic) BOOL inputEnabled;
@property (nonatomic) BOOL initialized;

- (BOOL)initAudioUnitWithSampleRate:(Float64)sampleRate numberChannels:(int)numChannels inputEnabled:(BOOL)inputEnabled;
- (void)destroyAudioUnit;
- (AudioComponentDescription)ioDescription;
- (AudioStreamBasicDescription)ASBDForSampleRate:(Float64)sampleRate numberChannels:(UInt32)numChannels;

@end

@implementation PdAudioUnit

@synthesize audioUnit = audioUnit_;
@synthesize active = active_;
@synthesize inputEnabled = inputEnabled_;
@synthesize initialized = initialized_;

#pragma mark - Init / Dealloc

- (id)init {
    self = [super init];
    if (self) {
        initialized_ = NO;
		active_ = NO;
		blockSizeAsLog_ = log2int([PdBase getBlockSize]);
	}
	return self;
}

- (void)dealloc {
	[self destroyAudioUnit];
	[super dealloc];
}

#pragma mark - Public Methods

- (PdAudioStatus)configureWithNumberInputChannels:(int)numInputs numberOutputChannels:(int)numOutputs {
	Boolean wasActive = self.isActive;
    AVAudioSession *globalSession = [AVAudioSession sharedInstance];
    Float64 sampleRate = globalSession.currentHardwareSampleRate;
    inputEnabled_ = (numInputs > 0);
    int numChannels = (numInputs > numOutputs) ? numInputs : numOutputs;
	if (![self initAudioUnitWithSampleRate:sampleRate numberChannels:numChannels inputEnabled:self.inputEnabled]) {
        return PdAudioError;
    }
	[PdBase openAudioWithSampleRate:sampleRate inputChannels:numChannels outputChannels:numChannels];
	[PdBase computeAudio:YES];
	self.active = wasActive;
	return PdAudioOK;
}

- (void)setActive:(BOOL)active {
    if (!self.initialized) return;
    if (active == active_) return;
    if (active) {
        AU_CHECK_STATUS(AudioOutputUnitStart(audioUnit_));
    } else {
        AU_CHECK_STATUS(AudioOutputUnitStop(audioUnit_));
    }
    active_ = active;
}

#pragma mark - AURenderCallback

static OSStatus AudioRenderCallback(void *inRefCon,
									AudioUnitRenderActionFlags *ioActionFlags,
									const AudioTimeStamp *inTimeStamp,
									UInt32 inBusNumber,
									UInt32 inNumberFrames,
									AudioBufferList *ioData) {
	
	PdAudioUnit *pdAudioUnit = (PdAudioUnit *)inRefCon;
	Float32 *auBuffer = (Float32 *)ioData->mBuffers[0].mData;
    
	if (pdAudioUnit->inputEnabled_) {
		AudioUnitRender(pdAudioUnit->audioUnit_, ioActionFlags, inTimeStamp, kInputElement, inNumberFrames, ioData);
	}
    
	int ticks = inNumberFrames >> pdAudioUnit->blockSizeAsLog_; // this is a faster way of computing (inNumberFrames / blockSize)
	[PdBase processFloatWithInputBuffer:auBuffer outputBuffer:auBuffer ticks:ticks];
	return noErr;
}

#pragma mark - Private

- (void)destroyAudioUnit {
    if (!self.initialized) return;
    self.active = NO;
    initialized_ = NO;
	AU_CHECK_STATUS(AudioUnitUninitialize(audioUnit_));
	AU_CHECK_STATUS(AudioComponentInstanceDispose(audioUnit_));
	AU_LOGV(@"destroyed audio unit");
}

- (BOOL)initAudioUnitWithSampleRate:(Float64)sampleRate numberChannels:(int)numChannels inputEnabled:(BOOL)inputEnabled {
    [self destroyAudioUnit];
	AudioComponentDescription ioDescription = [self ioDescription];
	AudioComponent audioComponent = AudioComponentFindNext(NULL, &ioDescription);
	AU_CHECK_STATUS_FALSE(AudioComponentInstanceNew(audioComponent, &audioUnit_));
    
    AudioStreamBasicDescription streamDescription = [self ASBDForSampleRate:sampleRate numberChannels:numChannels];
    if (inputEnabled) {
		UInt32 enableInput = 1;
		AU_CHECK_STATUS_FALSE(AudioUnitSetProperty(audioUnit_,
                                                   kAudioOutputUnitProperty_EnableIO,
                                                   kAudioUnitScope_Input,
                                                   kInputElement,
                                                   &enableInput,
                                                   sizeof(enableInput)));
		
		AU_CHECK_STATUS_FALSE(AudioUnitSetProperty(audioUnit_,
                                                   kAudioUnitProperty_StreamFormat,
                                                   kAudioUnitScope_Output,  // Output scope because we're defining the output of the input element to our render callback
                                                   kInputElement,
                                                   &streamDescription,
                                                   sizeof(streamDescription)));
	}
	
	AU_CHECK_STATUS_FALSE(AudioUnitSetProperty(audioUnit_,
                                               kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Input,  // Input scope because we're defining the input of the output element _from_ our render callback.
                                               kOutputElement,
                                               &streamDescription,
                                               sizeof(streamDescription)));
	
	AURenderCallbackStruct callbackStruct;
	callbackStruct.inputProc = AudioRenderCallback;
	callbackStruct.inputProcRefCon = self;
	AU_CHECK_STATUS_FALSE(AudioUnitSetProperty(audioUnit_,
                                               kAudioUnitProperty_SetRenderCallback,
                                               kAudioUnitScope_Input,
                                               kOutputElement,
                                               &callbackStruct,
                                               sizeof(callbackStruct)));
    
	AU_CHECK_STATUS_FALSE(AudioUnitInitialize(audioUnit_));
    initialized_ = YES;
	AU_LOGV(@"initialized audio unit");
	return true;
}

- (AudioComponentDescription)ioDescription {
	AudioComponentDescription description;
	description.componentType = kAudioUnitType_Output;
	description.componentSubType = kAudioUnitSubType_RemoteIO;
	description.componentManufacturer = kAudioUnitManufacturer_Apple;
	description.componentFlags = 0;
	description.componentFlagsMask = 0;
	return description;
}

// sets the format to 32 bit, floating point, linear PCM, interleaved
- (AudioStreamBasicDescription)ASBDForSampleRate:(Float64)sampleRate numberChannels:(UInt32)numberChannels {
	const int kFloatSize = 4;
	const int kBitSize = 8;
    
	AudioStreamBasicDescription description;
	memset(&description, 0, sizeof(description));
	
	description.mSampleRate = sampleRate;
	description.mFormatID = kAudioFormatLinearPCM;
	description.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	description.mBytesPerPacket = kFloatSize * numberChannels;
	description.mFramesPerPacket = 1;
	description.mBytesPerFrame = kFloatSize * numberChannels;
	description.mChannelsPerFrame = numberChannels;
	description.mBitsPerChannel = kFloatSize * kBitSize;
	
	return description;
}

- (void)print {
    if (!self.initialized) {
		AU_LOG(@"Audio Unit not initialized");
        return;
    }
    
	UInt32 sizeASBD = sizeof(AudioStreamBasicDescription);
    
	if (self.inputEnabled) {
		AudioStreamBasicDescription inputStreamDescription;
		memset (&inputStreamDescription, 0, sizeof(inputStreamDescription));
		AU_CHECK_STATUS(AudioUnitGetProperty(audioUnit_,
											 kAudioUnitProperty_StreamFormat,
											 kAudioUnitScope_Output,
											 kInputElement,
											 &inputStreamDescription,
											 &sizeASBD));
		AU_LOG(@"input ASBD:");
		AU_LOG(@"  mSampleRate: %.0fHz", inputStreamDescription.mSampleRate);
		AU_LOG(@"  mChannelsPerFrame: %lu", inputStreamDescription.mChannelsPerFrame);
		AU_LOGV(@"  mFormatID: %lu", inputStreamDescription.mFormatID);
		AU_LOGV(@"  mFormatFlags: %lu", inputStreamDescription.mFormatFlags);
		AU_LOGV(@"  mBytesPerPacket: %lu", inputStreamDescription.mBytesPerPacket);
		AU_LOGV(@"  mFramesPerPacket: %lu", inputStreamDescription.mFramesPerPacket);
		AU_LOGV(@"  mBytesPerFrame: %lu", inputStreamDescription.mBytesPerFrame);
		AU_LOGV(@"  mBitsPerChannel: %lu", inputStreamDescription.mBitsPerChannel);
	} else {
		AU_LOG(@"no input ASBD");
	}
    
	AudioStreamBasicDescription outputStreamDescription;
	memset(&outputStreamDescription, 0, sizeASBD);
	AU_CHECK_STATUS(AudioUnitGetProperty(audioUnit_,
										 kAudioUnitProperty_StreamFormat,
										 kAudioUnitScope_Input,
										 kOutputElement,
										 &outputStreamDescription,
										 &sizeASBD));
	AU_LOG(@"output ASBD:");
	AU_LOG(@"  mSampleRate: %.0fHz", outputStreamDescription.mSampleRate);
	AU_LOG(@"  mChannelsPerFrame: %lu", outputStreamDescription.mChannelsPerFrame);
	AU_LOGV(@"  mFormatID: %lu", outputStreamDescription.mFormatID);
	AU_LOGV(@"  mFormatFlags: %lu", outputStreamDescription.mFormatFlags);
	AU_LOGV(@"  mBytesPerPacket: %lu", outputStreamDescription.mBytesPerPacket);
	AU_LOGV(@"  mFramesPerPacket: %lu", outputStreamDescription.mFramesPerPacket);
	AU_LOGV(@"  mBytesPerFrame: %lu", outputStreamDescription.mBytesPerFrame);
	AU_LOGV(@"  mBitsPerChannel: %lu", outputStreamDescription.mBitsPerChannel);
}

@end
