/**************************************************************************/
/*  native_video_view.m                                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#import "native_video_view.h"

#import <AVFoundation/AVFoundation.h>
#include <math.h>

static void *GodotVideoItemStatusContext = &GodotVideoItemStatusContext;
static void *GodotVideoPlayerStatusContext = &GodotVideoPlayerStatusContext;

@interface GodotNativeVideoView ()

@property(strong, nonatomic) AVAsset *avAsset;
@property(strong, nonatomic) AVPlayerItem *avPlayerItem;
@property(strong, nonatomic) AVPlayer *avPlayer;
@property(strong, nonatomic) AVPlayerLayer *avPlayerLayer;
@property(assign, nonatomic) BOOL observesItemStatus;
@property(assign, nonatomic) BOOL observesPlayerStatus;
@property(assign, nonatomic) BOOL userPaused;
@property(assign, nonatomic) BOOL lifecyclePaused;

@end

@implementation GodotNativeVideoView

- (void)layoutSubviews {
	[super layoutSubviews];
	self.avPlayerLayer.frame = self.bounds;
}

- (void)updatePlayback {
	if (!self.avPlayer) {
		return;
	}
	if (self.avPlayer.status == AVPlayerStatusFailed || self.avPlayerItem.status == AVPlayerItemStatusFailed) {
		[self stopVideo];
		return;
	}
	if (self.userPaused || self.lifecyclePaused) {
		[self.avPlayer pause];
	} else {
		// AVPlayer waits for the item to become ready. Never infer playback intent
		// from rate: it is also zero while buffering or intentionally paused.
		[self.avPlayer play];
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (context != GodotVideoItemStatusContext && context != GodotVideoPlayerStatusContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			// Ignore callbacks queued by an item which stop/replay already replaced.
			if (object == self.avPlayerItem || object == self.avPlayer) {
				[self updatePlayback];
			}
		});
		return;
	}
	if (object == self.avPlayerItem || object == self.avPlayer) {
		[self updatePlayback];
	}
}

- (BOOL)playVideoAtPath:(NSString *)filePath volume:(float)videoVolume audio:(NSString *)audioTrack subtitle:(NSString *)subtitleTrack {
	[self finishPlayingVideo];
	self.userPaused = NO;
	// ViewController supplies the current scene/audio gate before replacement.
	// Keep it while the new AVPlayer and its status observers are created.

	self.avAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
	self.avPlayerItem = [AVPlayerItem playerItemWithAsset:self.avAsset];
	self.avPlayer = [AVPlayer playerWithPlayerItem:self.avPlayerItem];
	self.avPlayer.volume = fminf(1.0f, fmaxf(0.0f, videoVolume));
	self.avPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:self.avPlayer];
	self.avPlayerLayer.frame = self.bounds;
	[self.layer addSublayer:self.avPlayerLayer];

	[self.avPlayerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:GodotVideoItemStatusContext];
	self.observesItemStatus = YES;
	[self.avPlayer addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:GodotVideoPlayerStatusContext];
	self.observesPlayerStatus = YES;
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.avPlayerItem];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.avPlayerItem];

	AVMediaSelectionGroup *audioGroup = [self.avAsset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
	for (AVMediaSelectionOption *option in audioGroup.options) {
		if ([option.locale.localeIdentifier isEqualToString:audioTrack]) {
			[self.avPlayerItem selectMediaOption:option inMediaSelectionGroup:audioGroup];
			break;
		}
	}

	AVMediaSelectionGroup *subtitleGroup = [self.avAsset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
	if (subtitleGroup) {
		NSArray<AVMediaSelectionOption *> *options = [AVMediaSelectionGroup mediaSelectionOptionsFromArray:subtitleGroup.options withoutMediaCharacteristics:@[ AVMediaCharacteristicContainsOnlyForcedSubtitles ]];
		for (AVMediaSelectionOption *option in options) {
			if ([option.locale.localeIdentifier isEqualToString:subtitleTrack]) {
				[self.avPlayerItem selectMediaOption:option inMediaSelectionGroup:subtitleGroup];
				break;
			}
		}
	}

	[self updatePlayback];
	return self.avPlayer != nil;
}

- (BOOL)isVideoPlaying {
	return self.avPlayer && !self.userPaused && !self.lifecyclePaused && self.avPlayer.rate > 0.0f && !self.avPlayer.error;
}

- (void)pauseVideo {
	self.userPaused = YES;
	[self updatePlayback];
}

- (void)unpauseVideo {
	self.userPaused = NO;
	[self updatePlayback];
}

- (void)unfocusVideo {
	self.lifecyclePaused = YES;
	[self updatePlayback];
}

- (void)focusVideo {
	self.lifecyclePaused = NO;
	[self updatePlayback];
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self playerItemDidReachEnd:notification];
		});
		return;
	}
	if (notification.object == self.avPlayerItem) {
		[self stopVideo];
	}
}

- (void)finishPlayingVideo {
	AVPlayerItem *item = self.avPlayerItem;
	AVPlayer *player = self.avPlayer;
	// Clear identity before removing observers so stale queued callbacks cannot
	// start a replacement player or resume a stopped video.
	self.avPlayerItem = nil;
	self.avPlayer = nil;
	if (item) {
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
		if (self.observesItemStatus) {
			[item removeObserver:self forKeyPath:@"status" context:GodotVideoItemStatusContext];
		}
	}
	if (player && self.observesPlayerStatus) {
		[player removeObserver:self forKeyPath:@"status" context:GodotVideoPlayerStatusContext];
	}
	self.observesItemStatus = NO;
	self.observesPlayerStatus = NO;
	[player pause];
	[player replaceCurrentItemWithPlayerItem:nil];
	[self.avPlayerLayer removeFromSuperlayer];
	self.avPlayerLayer = nil;
	self.avAsset = nil;
}

- (void)stopVideo {
	[self finishPlayingVideo];
	[self removeFromSuperview];
}

- (void)dealloc {
	[self finishPlayingVideo];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
