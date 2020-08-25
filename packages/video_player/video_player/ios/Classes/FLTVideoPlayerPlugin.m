// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTVideoPlayerPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <GLKit/GLKit.h>
#import "messages.h"

#import <Photos/Photos.h>
#import "VIMediaCache.h"

// TODO(recastrodiaz) remove duplicate interface. Taken from messages.m
@interface FLTTextureMessage ()
+ (FLTTextureMessage*)fromMap:(NSDictionary*)dict;
- (NSDictionary*)toMap;
@end

@interface VIMediaCacheSingleton : NSObject {
  VIResourceLoaderManager* resourceLoaderManager;
}

@property(nonatomic, retain) VIResourceLoaderManager* resourceLoaderManager;

+ (id)sharedVIMediaCache;

@end

@implementation VIMediaCacheSingleton

@synthesize resourceLoaderManager;

#pragma mark Singleton Methods

+ (id)sharedVIMediaCache {
  static VIResourceLoaderManager* shared = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    shared = [[self alloc] init];
  });
  return shared;
}

- (id)init {
  if (self = [super init]) {
    resourceLoaderManager = [VIResourceLoaderManager new];
  }
  return self;
}

- (void)dealloc {
  // Should never be called, but just here for clarity really.
}

@end

#pragma mark FLTFrameUpdater
#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif

int64_t FLTCMTimeToMillis(CMTime time) {
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

@interface FLTFrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, weak, readonly) NSObject<FlutterTextureRegistry>* registry;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation FLTFrameUpdater
- (FLTFrameUpdater*)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry {
  NSAssert(self, @"super init cannot be nil");
  if (self == nil) return nil;
  _registry = registry;
  return self;
}

- (void)onDisplayLink:(CADisplayLink*)link {
  [_registry textureFrameAvailable:_textureId];
}
@end

#pragma mark FLTVideoPlayer

@interface FLTVideoPlayer : NSObject <FlutterTexture, FlutterStreamHandler>
@property(readonly, nonatomic) AVPlayer* player;
@property(nonatomic) AVAsset* fullAsset;
@property(readonly, nonatomic) AVPlayerItemVideoOutput* videoOutput;
@property(readonly, nonatomic) CADisplayLink* displayLink;
@property(nonatomic) FlutterEventChannel* eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic, readonly) bool disposed;
@property(nonatomic, readonly) bool isPlaying;
@property(nonatomic) CMTime computedSeektoPosition;
@property(nonatomic) bool isLooping;
@property(nonatomic, readonly) bool isInitialized;
@property(nonatomic) CMTime startPosition;
@property(nonatomic) bool hasObservers;
@property(nonatomic) bool outputInSync;
@property(nonatomic) bool scrubbingDisabled;
@property(nonatomic) void (^sendInitializeEvent)(void);
- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater;
- (void)play;
- (void)pause;
- (void)setIsLooping:(bool)isLooping;
- (void)updatePlayingState;
@end

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;

@implementation FLTVideoPlayer

- (instancetype)initWithAsset:(NSString*)asset frameUpdater:(FLTFrameUpdater*)frameUpdater {
  NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
  return [self initWithURL:[NSURL fileURLWithPath:path] frameUpdater:frameUpdater];
}

- (void)initWithPHAssetLocalIdentifier:(NSString*)localIdentifier
                          frameUpdater:(FLTFrameUpdater*)frameUpdater
                       onPlayerCreated:
                           (void (^)(FLTVideoPlayer* playerItem))onPlayerCreatedHandler {
  PHFetchResult<PHAsset*>* phFetchResult =
      [PHAsset fetchAssetsWithLocalIdentifiers:@[ localIdentifier ] options:nil];
  // TODO what to do if the asset cannot be loaded? Send an error to flutter?
  PHAsset* phAsset = [phFetchResult firstObject];
  NSLog(@"PHFetchResult loaded: %@", phFetchResult);
  NSLog(@"PHAsset loaded: %@", phAsset);
  PHCachingImageManager* imageManager = [[PHCachingImageManager alloc] init];
  [imageManager requestPlayerItemForVideo:phAsset
                                  options:nil
                            resultHandler:^(AVPlayerItem* _Nullable playerItem,
                                            NSDictionary* _Nullable info) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                FLTVideoPlayer* fltvPlayer = [self initWithPlayerItem:playerItem
                                                                         frameUpdater:frameUpdater];
                                onPlayerCreatedHandler(fltvPlayer);
                              });
                            }];
}

- (void)addObservers:(AVPlayerItem*)item {
  if (self.hasObservers) {
    NSLog(@"ERROR: Observers already present. Please remove them first");
  }

  self.hasObservers = YES;
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferEmpty"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferEmptyContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferFull"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferFullContext];

  // Add an observer that will respond to itemDidPlayToEndTime
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(itemDidPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];
}

- (void)itemDidPlayToEndTime:(NSNotification*)notification {
  if (_isLooping) {
    AVPlayerItem* p = [notification object];
    [p seekToTime:kCMTimeZero completionHandler:nil];
  } else {
    if (_eventSink) {
      _eventSink(@{@"event" : @"completed"});
    }
  }
}

static inline CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360[
  return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                 withTimeRange:(CMTimeRange)timeRange
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
  AVMutableVideoCompositionInstruction* instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = timeRange;

  AVMutableVideoCompositionLayerInstruction* layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  // TODO(@recastrodiaz): should we use videoTrack.nominalFrameRate ?
  // Currently set at a constant 30 FPS
  videoComposition.frameDuration = CMTimeMake(1, 30);

  return videoComposition;
}

- (void)createVideoOutputAndDisplayLink:(FLTFrameUpdater*)frameUpdater {
  NSDictionary* pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];

  _displayLink = [CADisplayLink displayLinkWithTarget:frameUpdater
                                             selector:@selector(onDisplayLink:)];
  [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  _displayLink.paused = YES;
}

- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater {
  VIMediaCacheSingleton* shared = [VIMediaCacheSingleton sharedVIMediaCache];
  AVPlayerItem* item = [shared.resourceLoaderManager playerItemWithURL:url];

  // TODO(@recastrodiaz) Sometimes when loading the videos from cache, the video cannot be loaded
  // with errors like:
  //
  // Could not load video tracks: 3 - Error Domain=AVFoundationErrorDomain
  // Code=-11829 "Cannot Open" UserInfo={NSUnderlyingError=0x28117e190 {Error
  // Domain=NSOSStatusErrorDomain Code=-12848 "(null)"}, NSLocalizedFailureReason=This media may be
  // damaged., NSURL=__VIMediaCache___:https://example.com/video.mp4, NSLocalizedDescription=Cannot
  // Open}
  //
  // The following block is ran when an http video cannot be loaded for the first time. It attempts
  // to loading again. This is a workaround which seems to work well. A better fix would not try to
  // play the video until the file is actually ready to be played. Issue tracked here:
  // https://github.com/flutter/flutter/issues/28094#issuecomment-543197885
  void (^onVideoLoadingErrorHandler)(void) = ^{
    if ([url.absoluteString hasPrefix:@"http"]) {
      NSLog(@"onVideoLoadingErrorHandler. Trying to load video again");
      AVPlayerItem* item = [shared.resourceLoaderManager playerItemWithURL:url];
      [self initWithPlayerItem:item onVideoLoadingErrorHandler:nil];
    }
  };

  [self createVideoOutputAndDisplayLink:frameUpdater];
  return [self initWithPlayerItem:item onVideoLoadingErrorHandler:onVideoLoadingErrorHandler];
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform. This is because the transform.tx and transform.ty values are
  // incorrectly set to 0.
  // Setting the transform.tx value to the height of the video instead of 0 when rotationDegrees ==
  // 90 and transform.ty to the video width when rotationDegrees == 270, properly displays the video
  // https://github.com/flutter/flutter/issues/17606#issuecomment-413473181 In 1 other user video
  // the transform.x and transform.y are set to 1080.0 and 0.0 respectively, whilst the width,
  // height and rotation of the video are 848.0, 480.0 and 90 respectively. Replacing the value of
  // transform.tx to the video height properly renders the video.
  NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
  NSLog(@"VIDEO__ %f, %f, %f, %f, %li", transform.tx, transform.ty, videoTrack.naturalSize.width,
        videoTrack.naturalSize.height, (long)rotationDegrees);
  if (rotationDegrees == 90) {
    transform.tx = videoTrack.naturalSize.height;
    transform.ty = 0;
  } else if (rotationDegrees == 180) {
    transform.tx = videoTrack.naturalSize.width;
    transform.ty = videoTrack.naturalSize.height;
  } else if (rotationDegrees == 270) {
    transform.tx = 0;
    transform.ty = videoTrack.naturalSize.width;
  }
  return transform;
}

- (instancetype)initWithPlayerItem:(AVPlayerItem*)item frameUpdater:(FLTFrameUpdater*)frameUpdater {
  [self createVideoOutputAndDisplayLink:frameUpdater];
  return [self initWithPlayerItem:item onVideoLoadingErrorHandler:nil];
}

- (instancetype)initWithPlayerItem:(AVPlayerItem*)item
        onVideoLoadingErrorHandler:(void (^)(void))onVideoLoadingErrorHandler {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _isInitialized = false;
  _outputInSync = false;
  _isPlaying = false;
  _disposed = false;
  _scrubbingDisabled = false;

  AVAsset* asset = [item asset];
  void (^assetCompletionHandler)(void) = ^{
    NSError* tracksError = nil;
    AVKeyValueStatus trackStatus = [asset statusOfValueForKey:@"tracks" error:&tracksError];
    if (trackStatus == AVKeyValueStatusLoaded) {
      // Load the observers here so we don't complete the error future twice
      [self addObservers:item];

      NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if ([tracks count] > 0) {
        NSLog(@"Tracks count %ld", [tracks count]);
        AVAssetTrack* videoTrack = tracks[0];
        void (^trackCompletionHandler)(void) = ^{
          if (self->_disposed) return;
          self.fullAsset = asset;
          if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                        error:nil] == AVKeyValueStatusLoaded) {
            // Rotate the video by using a videoComposition and the preferredTransform
            self->_preferredTransform = [self fixTransform:videoTrack];
            // Note:
            // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
            // Video composition can only be used with file-based media and is not supported for
            // use with media served using HTTP Live Streaming.
            CMTimeRange timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
            AVMutableVideoComposition* videoComposition =
                [self getVideoCompositionWithTransform:self->_preferredTransform
                                         withTimeRange:timeRange
                                        withVideoTrack:videoTrack];
            item.videoComposition = videoComposition;
          } else {
            NSLog(@"Video has no preferredTransform");
          }
        };
        [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                  completionHandler:trackCompletionHandler];
      } else {
        NSLog(@"Video has not tracks");
      }
    } else {
      NSLog(@"Could not load video tracks: %ld - %@", (long)trackStatus, tracksError);
      if (onVideoLoadingErrorHandler != nil) {
        onVideoLoadingErrorHandler();
      }
    }
  };

  _player = [AVPlayer playerWithPlayerItem:item];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

  _startPosition = kCMTimeZero;

  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

  return self;
}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
      for (NSValue* rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FLTCMTimeToMillis(range.start) + FLTCMTimeToMillis(_startPosition);
        [values addObject:@[ @(start), @(start + FLTCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem* item = (AVPlayerItem*)object;
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        NSLog(@"Video AVPlayerItemStatusFailed");
        if (_eventSink != nil) {
          _eventSink([FlutterError
              errorWithCode:@"VideoError"
                    message:[@"Failed to load video: "
                                stringByAppendingString:[item.error localizedDescription]]
                    details:nil]);
        }
        break;
      case AVPlayerItemStatusUnknown:
        NSLog(@"Video AVPlayerItemStatusUnknown");
        break;
      case AVPlayerItemStatusReadyToPlay:
        NSLog(@"Video AVPlayerItemStatusReadyToPlay");
        [self onReadyToPlay:item];
        break;
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      [self updatePlayingState];
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    }
  } else if (context == playbackBufferEmptyContext) {
    if (_eventSink != nil) {
      _eventSink(@{@"event" : @"bufferingStart"});
    }
  } else if (context == playbackBufferFullContext) {
    if (_eventSink != nil) {
      _eventSink(@{@"event" : @"bufferingEnd"});
    }
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    [_player play];
  } else {
    [_player pause];
  }
  _displayLink.paused = !_isPlaying;
}

- (void)onReadyToPlay:(AVPlayerItem*)item {
  [self sendInitialized:item];
  [self updatePlayingState];
}

- (void)sendInitialized:(AVPlayerItem*)item {
  void (^sendInitializeEvent)(void) = ^{
    NSLog(@"sendInitialized (1)");
    CGSize size = [self.player currentItem].presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    // The player has not yet initialized.
    if (height == CGSizeZero.height && width == CGSizeZero.width) {
      return;
    }
    // The player may be initialized but still needs to determine the duration.
    if ([self duration] == 0) {
      return;
    }

    NSLog(@"sendInitialized (2)");

    self->_isInitialized = true;
    self->_eventSink(@{
      @"event" : @"initialized",
      @"duration" : @([self duration]),
      @"width" : @(width),
      @"height" : @(height)
    });

    self->_outputInSync = true;
    [item addOutput:self->_videoOutput];
    [self updatePlayingState];
  };

  if (!_isInitialized) {
    if (_eventSink) {
      sendInitializeEvent();
    } else {
      self.sendInitializeEvent = sendInitializeEvent;
    }
  } else {
    if (!_outputInSync) {
      [item addOutput:self->_videoOutput];
      [self updatePlayingState];
    }
  }
}

- (void)play {
  _isPlaying = true;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = false;
  [self updatePlayingState];
}

- (int64_t)position {
  return FLTCMTimeToMillis([_player currentTime]) + FLTCMTimeToMillis(_startPosition);
}

- (int64_t)duration {
  return FLTCMTimeToMillis([_fullAsset duration]);
}

- (void)seekTo:(int)location onSeekUpdate:(void (^)(void))onSeekUpdate {
  CMTime disiredPosition = CMTimeMake(location, 1000);
  CMTime computedPosition = CMTimeSubtract(disiredPosition, _startPosition);
  // NSLog(@"Computed positon: %f : %f", CMTimeGetSeconds(computedPosition),
  // CMTimeGetSeconds(disiredPosition));
  computedPosition =
      CMTimeClampToRange(computedPosition, CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity));
  NSLog(@"Computed positon (A): %f", CMTimeGetSeconds(computedPosition));

  self->_computedSeektoPosition = computedPosition;
  CMTime currentPosition = [_player currentTime];
  CMTime interval = CMTimeSubtract(computedPosition, currentPosition);
  CMTime intervalStep = CMTimeMultiplyByFloat64(interval, 1.0 / 15.0);

  if (CMTIME_COMPARE_INLINE(intervalStep, ==, kCMTimeZero)) {
    // Do nothing if the target position is the same
    NSLog(@"NOP");
    return;
  }

  CMTime nextFrame = CMTimeAdd(currentPosition, intervalStep);
  if (CMTIME_COMPARE_INLINE(CMTimeAbsoluteValue(interval), >, CMTimeMake(3, 1))) {
    // DO not scrub if interval is larger than 4 seconds
    nextFrame = computedPosition;
    NSLog(@"Skip scrubbing > 3 seconds: %f", CMTimeGetSeconds(CMTimeMake(3, 1)));
  }

  if (!_scrubbingDisabled) {
    [self delayedSeekTo:nextFrame
           intervalStep:intervalStep
         targetLocation:computedPosition
           onSeekUpdate:onSeekUpdate];
  } else {
    [self->_player seekToTime:self->_computedSeektoPosition
              toleranceBefore:kCMTimeZero
               toleranceAfter:kCMTimeZero];
  }
}

- (void)delayedSeekTo:(CMTime)location
         intervalStep:(CMTime)intervalStep
       targetLocation:(CMTime)targetLocation
         onSeekUpdate:(void (^)(void))onSeekUpdate {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self doSeekTo:location
          intervalStep:intervalStep
        targetLocation:targetLocation
          onSeekUpdate:onSeekUpdate];
  });
}

- (void)doSeekTo:(CMTime)location
      intervalStep:(CMTime)intervalStep
    targetLocation:(CMTime)targetLocation
      onSeekUpdate:(void (^)(void))onSeekUpdate {
  if (CMTIME_COMPARE_INLINE(targetLocation, !=, self->_computedSeektoPosition)) {
    // The seek to position has changed
    // Stop scrubbing
    NSLog(@"Seeking to (0): Cancelled");
    return;
  }

  NSLog(@"Seeking to (1): %f", CMTimeGetSeconds(location));
  [_player seekToTime:location
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL isFinished) {
        if (isFinished) {
          onSeekUpdate();
          CMTime currentPosition = [self->_player currentTime];
          if (CMTIME_COMPARE_INLINE(currentPosition, >=, targetLocation)) {
            NSLog(@"Seeking to (2): %f", CMTimeGetSeconds(location));
            [self->_player seekToTime:self->_computedSeektoPosition
                      toleranceBefore:kCMTimeZero
                       toleranceAfter:kCMTimeZero
                    completionHandler:^(BOOL isFinished) {
                      if (isFinished) {
                        onSeekUpdate();
                      } else {
                        NSLog(@"Seeking to (2): Cancelled");
                      }
                    }];
          } else {
            CMTime nextFrame = CMTimeAdd(location, intervalStep);
            [self delayedSeekTo:nextFrame
                   intervalStep:intervalStep
                 targetLocation:targetLocation
                   onSeekUpdate:onSeekUpdate];
          }
        } else {
          NSLog(@"Seeking to (1): Cancelled");
        }
      }];
}

- (void)setIsLooping:(bool)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setSpeed:(double)speed error:(FlutterError**)error {
  if (speed == 1.0 || speed == 0.0) {
    _player.rate = speed;
  } else if (speed < 0 || speed > 2.0) {
    *error = [FlutterError errorWithCode:@"unsupported_speed"
                                 message:@"Speed must be >= 0.0 and <= 2.0"
                                 details:nil];
  } else if ((speed > 1.0 && _player.currentItem.canPlayFastForward) ||
             (speed < 1.0 && _player.currentItem.canPlaySlowForward)) {
    _player.rate = speed;
  } else {
    if (speed > 1.0) {
      *error = [FlutterError errorWithCode:@"unsupported_fast_forward"
                                   message:@"This video cannot be played fast forward"
                                   details:nil];
    } else {
      *error = [FlutterError errorWithCode:@"unsupported_slow_forward"
                                   message:@"This video cannot be played slow forward"
                                   details:nil];
    }
  }
}

- (void)clip:(long)startMs endMs:(long)endMs error:(FlutterError**)error {
  if (self->_disposed) {
    return;
  }

  // For some reason scrubbing doesn't work well when clipping the video
  _scrubbingDisabled = true;

  CMTime videoDuration = _fullAsset.duration;
  if (CMTIME_IS_INDEFINITE(videoDuration)) {
    *error = [FlutterError errorWithCode:@"video_not_ready"
                                 message:@"Do not call clip until the video is ready to play"
                                 details:nil];
  } else if (self.fullAsset == nil) {
    *error = [FlutterError errorWithCode:@"video_asset_not_ready"
                                 message:@"Do not call clip until the video is ready to play"
                                 details:nil];
  } else if (startMs < 0 || endMs <= startMs || endMs > 1000 * CMTimeGetSeconds(videoDuration)) {
    *error = [FlutterError errorWithCode:@"unsupported_clip_parameters"
                                 message:@"startMs must be >= 0.0 and < endMs and endMs <= duration"
                                 details:nil];
  } else {
    CMTime start = CMTimeMake(startMs, 1000);
    _startPosition = start;
    CMTime duration = CMTimeMake(endMs - startMs, 1000);

    NSError* videoError = nil;
    AVMutableVideoComposition* videoComposition = nil;
    AVMutableComposition* mutableComposition = [AVMutableComposition composition];
    if ([[self.fullAsset tracksWithMediaType:AVMediaTypeVideo] count] != 0) {
      AVAssetTrack* videoTrack =
          [[self.fullAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];

      AVMutableCompositionTrack* videoComTrack =
          [mutableComposition addMutableTrackWithMediaType:AVMediaTypeVideo
                                          preferredTrackID:kCMPersistentTrackID_Invalid];
      [videoComTrack insertTimeRange:CMTimeRangeMake(start, duration)
                             ofTrack:videoTrack
                              atTime:kCMTimeZero
                               error:&videoError];

      videoComposition =
          [self getVideoCompositionWithTransform:self->_preferredTransform
                                   withTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                                  withVideoTrack:videoTrack];
    }
    if ([[self.fullAsset tracksWithMediaType:AVMediaTypeAudio] count] != 0) {
      AVAssetTrack* audioTrack =
          [[self.fullAsset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];

      AVMutableCompositionTrack* audioComTrack =
          [mutableComposition addMutableTrackWithMediaType:AVMediaTypeAudio
                                          preferredTrackID:kCMPersistentTrackID_Invalid];
      [audioComTrack insertTimeRange:CMTimeRangeMake(start, duration)
                             ofTrack:audioTrack
                              atTime:kCMTimeZero
                               error:&videoError];
    }

    if (!videoError) {
      AVPlayerItem* newItem = [[AVPlayerItem alloc] initWithAsset:mutableComposition];

      if (videoComposition) {
        newItem.videoComposition = videoComposition;
      }
      [self removeAvPlayerObservers];

      [self->_player replaceCurrentItemWithPlayerItem:newItem];
      [self addObservers:newItem];
    } else {
      *error = [FlutterError
          errorWithCode:@"clip_error"
                message:@"Could not clip video from \(start) with duration \(duration)"
                details:videoError];
    }
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    return [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
  } else {
    return NULL;
  }
}

- (void)onTextureUnregistered {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self dispose];
  });
}

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
  // https://github.com/flutter/flutter/issues/21483
  // This line ensures the 'initialized' event is sent when the event
  // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
  // onListenWithArguments is called)
  if (self.sendInitializeEvent != nil) {
    self.sendInitializeEvent();
    self.sendInitializeEvent = nil;
  }
  return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
  _disposed = true;
  [_displayLink invalidate];
  [self removeAvPlayerObservers];
}

- (void)removeAvPlayerObservers {
  if (self.hasObservers) {
    self.hasObservers = NO;

    [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
    [[_player currentItem] removeObserver:self
                               forKeyPath:@"loadedTimeRanges"
                                  context:timeRangeContext];
    [[_player currentItem] removeObserver:self
                               forKeyPath:@"playbackLikelyToKeepUp"
                                  context:playbackLikelyToKeepUpContext];
    [[_player currentItem] removeObserver:self
                               forKeyPath:@"playbackBufferEmpty"
                                  context:playbackBufferEmptyContext];
    [[_player currentItem] removeObserver:self
                               forKeyPath:@"playbackBufferFull"
                                  context:playbackBufferFullContext];
    _outputInSync = false;
    [_player replaceCurrentItemWithPlayerItem:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
  } else {
    NSLog(@"WARN: Not removing observers as they aren't present.");
  }
}

- (void)dispose {
  _disposed = true;
  [self disposeSansEventChannel];
  [_eventChannel setStreamHandler:nil];
}

@end

@interface FLTVideoPlayerPlugin () <FLTVideoPlayerApi>
@property(readonly, weak, nonatomic) NSObject<FlutterTextureRegistry>* registry;
@property(readonly, weak, nonatomic) NSObject<FlutterBinaryMessenger>* messenger;
@property(readonly, strong, nonatomic) NSMutableDictionary* players;
@property(readonly, strong, nonatomic) NSObject<FlutterPluginRegistrar>* registrar;
@end

@implementation FLTVideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FLTVideoPlayerPlugin* instance = [[FLTVideoPlayerPlugin alloc] initWithRegistrar:registrar];
  [registrar publish:instance];
  FLTVideoPlayerApiSetup(registrar.messenger, instance);
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [registrar textures];
  _messenger = [registrar messenger];
  _registrar = registrar;
  _players = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  for (NSNumber* textureId in _players.allKeys) {
    FLTVideoPlayer* player = _players[textureId];
    [player disposeSansEventChannel];
  }
  [_players removeAllObjects];
  // TODO(57151): This should be commented out when 57151's fix lands on stable.
  // This is the correct behavior we never did it in the past and the engine
  // doesn't currently support it.
  // FLTVideoPlayerApiSetup(registrar.messenger, nil);
}

- (FLTTextureMessage*)onPlayerSetup:(FLTVideoPlayer*)player
                       frameUpdater:(FLTFrameUpdater*)frameUpdater {
  int64_t textureId = [_registry registerTexture:player];
  frameUpdater.textureId = textureId;
  FlutterEventChannel* eventChannel = [FlutterEventChannel
      eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                      textureId]
           binaryMessenger:_messenger];
  [eventChannel setStreamHandler:player];
  player.eventChannel = eventChannel;
  _players[@(textureId)] = player;
  FLTTextureMessage* result = [[FLTTextureMessage alloc] init];
  result.textureId = @(textureId);
  return result;
}

- (void)initialize:(FlutterError* __autoreleasing*)error {
  // Allow audio playback when the Ring/Silent switch is set to silent
  [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];

  for (NSNumber* textureId in _players) {
    [_registry unregisterTexture:[textureId unsignedIntegerValue]];
    [_players[textureId] dispose];
  }
  [_players removeAllObjects];
}

- (FLTTextureMessage*)create:(FLTCreateMessage*)input
                       error:(FlutterError**)error
                    callback:(FlutterReply)callback {
  FLTFrameUpdater* frameUpdater = [[FLTFrameUpdater alloc] initWithRegistry:_registry];
  FLTVideoPlayer* player;

  if (input.asset) {
    NSString* assetPath;
    if (input.packageName) {
      assetPath = [_registrar lookupKeyForAsset:input.asset fromPackage:input.packageName];
    } else {
      assetPath = [_registrar lookupKeyForAsset:input.asset];
    }
    player = [[FLTVideoPlayer alloc] initWithAsset:assetPath frameUpdater:frameUpdater];
    FLTTextureMessage* output = [self onPlayerSetup:player frameUpdater:frameUpdater];
    callback(wrapResult([output toMap], *error));
    return nil;
  } else if (input.uri) {
    NSString* phAssetPrefix = @"phasset://";
    if ([input.uri hasPrefix:phAssetPrefix]) {
      NSString* phAssetArg = [input.uri substringFromIndex:[phAssetPrefix length]];
      NSLog(@"Loading PHAsset localIdentifier: %@", phAssetArg);

      [[FLTVideoPlayer alloc] initWithPHAssetLocalIdentifier:phAssetArg
                                                frameUpdater:frameUpdater
                                             onPlayerCreated:^(FLTVideoPlayer* player) {
                                               FLTTextureMessage* output =
                                                   [self onPlayerSetup:player
                                                          frameUpdater:frameUpdater];
                                               FlutterError* noError;
                                               callback(wrapResult([output toMap], noError));
                                             }];
      return nil;
    } else {
      player = [[FLTVideoPlayer alloc] initWithURL:[NSURL URLWithString:input.uri]
                                      frameUpdater:frameUpdater];
      FLTTextureMessage* output = [self onPlayerSetup:player frameUpdater:frameUpdater];
      callback(wrapResult([output toMap], *error));
      return nil;
    }
  } else {
    *error = [FlutterError errorWithCode:@"video_player" message:@"not implemented" details:nil];
    FLTTextureMessage* output = nil;
    callback(wrapResult([output toMap], *error));
    return nil;
  }
}

- (void)dispose:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [_registry unregisterTexture:input.textureId.intValue];
  [_players removeObjectForKey:input.textureId];
  // If the Flutter contains https://github.com/flutter/engine/pull/12695,
  // the `player` is disposed via `onTextureUnregistered` at the right time.
  // Without https://github.com/flutter/engine/pull/12695, there is no guarantee that the
  // texture has completed the un-reregistration. It may leads a crash if we dispose the
  // `player` before the texture is unregistered. We add a dispatch_after hack to make sure the
  // texture is unregistered before we dispose the `player`.
  //
  // TODO(cyanglaz): Remove this dispatch block when
  // https://github.com/flutter/flutter/commit/8159a9906095efc9af8b223f5e232cb63542ad0b is in
  // stable And update the min flutter version of the plugin to the stable version.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (!player.disposed) {
                     [player dispose];
                   }
                 });
}

- (void)setLooping:(FLTLoopingMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player setIsLooping:[input.isLooping boolValue]];
}

- (void)setVolume:(FLTVolumeMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player setVolume:[input.volume doubleValue]];
}

- (void)play:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player play];
}

- (FLTPositionMessage*)position:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  FLTPositionMessage* result = [[FLTPositionMessage alloc] init];
  result.position = @([player position]);
  return result;
}

- (void)seekTo:(FLTPositionMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player seekTo:[input.position intValue]
      onSeekUpdate:^(void) {
        [self->_registry textureFrameAvailable:[input.textureId intValue]];
      }];
}

- (void)setSpeed:(FLTSpeedMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player setSpeed:[input.speed doubleValue] error:error];
}

- (void)clip:(FLTClipMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player clip:[input.startMs longValue] endMs:[input.endMs longValue] error:error];
}

- (void)pause:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player pause];
}

// TODO(recastrodiaz) remove duplicate function. Taken from messages.m
static NSDictionary* wrapResult(NSDictionary* result, FlutterError* error) {
  NSDictionary* errorDict = (NSDictionary*)[NSNull null];
  if (error) {
    errorDict = [NSDictionary
        dictionaryWithObjectsAndKeys:(error.code ? error.code : [NSNull null]), @"code",
                                     (error.message ? error.message : [NSNull null]), @"message",
                                     (error.details ? error.details : [NSNull null]), @"details",
                                     nil];
  }
  return [NSDictionary dictionaryWithObjectsAndKeys:(result ? result : [NSNull null]), @"result",
                                                    errorDict, @"error", nil];

  -(void)setMixWithOthers : (FLTMixWithOthersMessage*)input error
      : (FlutterError * _Nullable __autoreleasing*)error {
    if ([input.mixWithOthers boolValue]) {
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                       withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                             error:nil];
    } else {
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    }
  }

  @end
