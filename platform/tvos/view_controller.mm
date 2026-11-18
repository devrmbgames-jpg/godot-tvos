/**************************************************************************/
/*  view_controller.mm                                                    */
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

#import "view_controller.h"

#include "core/project_settings.h"
#import "godot_view.h"
#import "godot_view_renderer.h"
#import "keyboard_input_view.h"
#import "native_video_view.h"
#include "os_appletv.h"

@interface ViewController () <GodotViewDelegate>

@property(strong, nonatomic) GodotViewRenderer *renderer;
@property(strong, nonatomic) GodotNativeVideoView *videoView;
@property(strong, nonatomic) GodotKeyboardInputView *keyboardView;

@property(strong, nonatomic) UIView *godotLoadingOverlay;
@property(assign, nonatomic) BOOL gameViewVisible;
@property(assign, nonatomic) BOOL keyboardInputActive;

@end

@implementation ViewController

- (GodotView *)godotView {
	return (GodotView *)self.view;
}

- (void)loadView {
	GodotView *view = [[GodotView alloc] init];
	[view initializeRendering];

	GodotViewRenderer *renderer = [[GodotViewRenderer alloc] init];

	self.renderer = renderer;
	self.view = view;

	view.renderer = self.renderer;
	view.delegate = self;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
	self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];

	if (self) {
		[self godot_commonInit];
	}

	return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
	self = [super initWithCoder:coder];

	if (self) {
		[self godot_commonInit];
	}

	return self;
}

- (void)godot_commonInit {
	// Deliver gameplay input through Game Controller profiles. Native
	// keyboards and presented view controllers temporarily use UIKit below.
	self.controllerUserInteractionEnabled = NO;
}

- (void)didReceiveMemoryWarning {
	[super didReceiveMemoryWarning];
	printf("*********** did receive memory warning!\n");
};

- (void)viewDidLoad {
	[super viewDidLoad];

	[self observeKeyboard];
	[self displayLoadingOverlay];
}

- (void)updateControllerInputRouting {
	BOOL native_ui = self.keyboardInputActive || !self.gameViewVisible || self.presentedViewController != nil;
	if (self.controllerUserInteractionEnabled != native_ui) {
		self.controllerUserInteractionEnabled = native_ui;
		if (native_ui) {
			[self.godotView cancelPendingInput];
		}
		OSAppleTV *os = OSAppleTV::get_singleton();
		if (os) {
			os->set_native_ui_input(native_ui);
		}
	}
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	self.gameViewVisible = YES;
	self.keyboardInputActive = self.keyboardView.isFirstResponder;
	[self updateControllerInputRouting];
	if (!self.controllerUserInteractionEnabled) {
		[self.godotView becomeFirstResponder];
	}
}

- (void)viewWillDisappear:(BOOL)animated {
	self.gameViewVisible = NO;
	[self updateControllerInputRouting];
	[super viewWillDisappear:animated];
}

- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
	// Switch before presentation begins, including sheets/overlays which do
	// not make the presenting controller disappear. The render delegate
	// restores routing after dismissal without replacing a plugin's delegate.
	self.controllerUserInteractionEnabled = YES;
	[self.godotView cancelPendingInput];
	OSAppleTV *os = OSAppleTV::get_singleton();
	if (os) {
		os->set_native_ui_input(true);
	}
	[super presentViewController:controller animated:animated completion:completion];
}

- (void)keyboardInputBegan:(NSNotification *)notification {
	if (notification.object == self.keyboardView || self.keyboardView.isFirstResponder) {
		self.keyboardInputActive = YES;
		[self updateControllerInputRouting];
	}
}

- (void)keyboardInputEnded:(NSNotification *)notification {
	self.keyboardInputActive = NO;
	[self updateControllerInputRouting];
	if (!self.controllerUserInteractionEnabled) {
		[self.godotView becomeFirstResponder];
	}
}

- (void)observeKeyboard {
	printf("******** setting up keyboard input view\n");
	self.keyboardView = [GodotKeyboardInputView new];
	[self.view addSubview:self.keyboardView];
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	// tvOS exposes text-field editing notifications, but not UIKeyboard notifications.
	[center addObserver:self selector:@selector(keyboardInputBegan:) name:UITextFieldTextDidBeginEditingNotification object:self.keyboardView];
	[center addObserver:self selector:@selector(keyboardInputEnded:) name:UITextFieldTextDidEndEditingNotification object:self.keyboardView];
}

- (void)displayLoadingOverlay {
	NSBundle *bundle = [NSBundle mainBundle];
	NSString *storyboardName = @"Launch Screen";

	if ([bundle pathForResource:storyboardName ofType:@"storyboardc"] == nil) {
		return;
	}

	UIStoryboard *launchStoryboard = [UIStoryboard storyboardWithName:storyboardName bundle:bundle];

	UIViewController *controller = [launchStoryboard instantiateInitialViewController];
	self.godotLoadingOverlay = controller.view;
	self.godotLoadingOverlay.frame = self.view.bounds;
	self.godotLoadingOverlay.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;

	[self.view addSubview:self.godotLoadingOverlay];
}

- (BOOL)godotViewFinishedSetup:(GodotView *)view {
	[self updateControllerInputRouting];
	[self.godotLoadingOverlay removeFromSuperview];
	self.godotLoadingOverlay = nil;

	return YES;
}

- (void)dealloc {
	[self.videoView stopVideo];
	self.videoView = nil;

	self.keyboardView = nil;

	self.renderer = nil;

	if (self.godotLoadingOverlay) {
		[self.godotLoadingOverlay removeFromSuperview];
		self.godotLoadingOverlay = nil;
	}

	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

// MARK: Native Video Player

- (BOOL)playVideoAtPath:(NSString *)filePath volume:(float)videoVolume audio:(NSString *)audioTrack subtitle:(NSString *)subtitleTrack {
	// If we are showing some video already, reuse existing view for new video.
	if (self.videoView) {
		if (!self.videoView.superview) {
			[self.view addSubview:self.videoView];
		}
		return [self.videoView playVideoAtPath:filePath volume:videoVolume audio:audioTrack subtitle:subtitleTrack];
	} else {
		// Create autoresizing view for video playback.
		GodotNativeVideoView *videoView = [[GodotNativeVideoView alloc] initWithFrame:self.view.bounds];
		videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.view addSubview:videoView];

		self.videoView = videoView;

		return [self.videoView playVideoAtPath:filePath volume:videoVolume audio:audioTrack subtitle:subtitleTrack];
	}
}

@end
