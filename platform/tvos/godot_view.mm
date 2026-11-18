/**************************************************************************/
/*  godot_view.mm                                                         */
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

#import "godot_view.h"

#include "core/project_settings.h"
#include "os_appletv.h"
#include "servers/audio_server.h"

#import <OpenGLES/EAGLDrawable.h>
#import <QuartzCore/QuartzCore.h>

#import "display_layer.h"
#import "godot_view_gesture_recognizer.h"
#import "godot_view_renderer.h"

@interface GodotView ()

@property(assign, nonatomic) BOOL isActive;
@property(assign, nonatomic) int fallbackMenuJoyId;

// CADisplayLink available on 3.1+ synchronizes the animation timer & drawing with the refresh rate of the display, only supports animation intervals of 1/60 1/30 & 1/15
@property(strong, nonatomic) CADisplayLink *displayLink;

// An animation timer that, when animation is started, will periodically call -drawView at the given rate.
// Only used if CADisplayLink is not
@property(strong, nonatomic) NSTimer *animationTimer;

@property(strong, nonatomic) CALayer<DisplayLayer> *renderingLayer;

@property(strong, nonatomic) GodotViewGestureRecognizer *delayGestureRecognizer;

@end

@implementation GodotView

// Implement this to override the default layer class (which is [CALayer class]).
// We do this so that our view will be backed by a layer that is capable of OpenGL ES rendering.
- (CALayer<DisplayLayer> *)initializeRendering {
	if (self.renderingLayer) {
		return self.renderingLayer;
	}

	CALayer<DisplayLayer> *layer = [GodotOpenGLLayer layer];

	layer.frame = self.bounds;
	layer.contentsScale = self.contentScaleFactor;

	[self.layer addSublayer:layer];
	self.renderingLayer = layer;

	[layer initializeDisplayLayer];

	return self.renderingLayer;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
	self = [super initWithCoder:coder];

	if (self) {
		[self godot_commonInit];
	}

	return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];

	if (self) {
		[self godot_commonInit];
	}

	return self;
}

// Stop animating and release resources when they are no longer needed.
- (void)dealloc {
	[self cancelPendingInput];
	[self stopRendering];

	self.renderer = nil;
	self.delegate = nil;

	if (self.renderingLayer) {
		[self.renderingLayer removeFromSuperlayer];
		self.renderingLayer = nil;
	}

	if (self.displayLink) {
		[self.displayLink invalidate];
		self.displayLink = nil;
	}

	if (self.animationTimer) {
		[self.animationTimer invalidate];
		self.animationTimer = nil;
	}

	if (self.delayGestureRecognizer) {
		self.delayGestureRecognizer = nil;
	}
}

- (void)godot_commonInit {
	self.fallbackMenuJoyId = -1;
	self.contentScaleFactor = [UIScreen mainScreen].nativeScale;

	// Initialize delay gesture recognizer
	GodotViewGestureRecognizer *gestureRecognizer = [[GodotViewGestureRecognizer alloc] init];
	self.delayGestureRecognizer = gestureRecognizer;
	[self addGestureRecognizer:self.delayGestureRecognizer];
}

- (void)startRendering {
	if (self.isActive) {
		return;
	}

	self.isActive = YES;

	printf("start animation!\n");

	if (self.useCADisplayLink) {
		self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawView)];

		// Approximate frame rate
		// assumes device refreshes at 60 fps
		int displayFPS = (NSInteger)(1.0 / self.renderingInterval);

		self.displayLink.preferredFramesPerSecond = displayFPS;

		// Setup DisplayLink in main thread
		[self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	} else {
		self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:self.renderingInterval target:self selector:@selector(drawView) userInfo:nil repeats:YES];
	}
}

- (void)stopRendering {
	if (!self.isActive) {
		return;
	}

	self.isActive = NO;

	printf("******** stop animation!\n");

	if (self.useCADisplayLink) {
		[self.displayLink invalidate];
		self.displayLink = nil;
	} else {
		[self.animationTimer invalidate];
		self.animationTimer = nil;
	}
}

// Updates the OpenGL view when the timer fires
- (void)drawView {
	if (!self.isActive) {
		printf("draw view not active!\n");
		return;
	}

	id<GodotViewRendererProtocol> renderer = self.renderer;
	CALayer<DisplayLayer> *renderingLayer = self.renderingLayer;

	if (!renderer || !renderingLayer) {
		return;
	}

	// Make the EAGL context current before Godot initializes or renders.
	[renderingLayer startRenderDisplayLayer];

	// setupView returns YES while engine initialization is still in progress.
	// Do not present the renderbuffer on those setup-only frames.
	if ([renderer setupView:self]) {
		return;
	}

	if (self.delegate) {
		BOOL delegateFinishedSetup = [self.delegate godotViewFinishedSetup:self];

		if (!delegateFinishedSetup) {
			return;
		}
	}

	[renderer renderOnView:self];

	// stopRenderDisplayLayer presents the completed OpenGL ES renderbuffer.
	[renderingLayer stopRenderDisplayLayer];
}

- (BOOL)canRender {
	if (self.useCADisplayLink) {
		return self.displayLink != nil;
	} else {
		return self.animationTimer != nil;
	}
}

- (void)setRenderingInterval:(NSTimeInterval)renderingInterval {
	_renderingInterval = renderingInterval;

	if (self.canRender) {
		[self stopRendering];
		[self startRendering];
	}
}

// If our view is resized, we'll be asked to layout subviews.
// This is the perfect opportunity to also update the framebuffer so that it is
// the same size as our display area.

- (void)layoutSubviews {
	if (self.renderingLayer) {
		self.renderingLayer.frame = self.bounds;
		[self.renderingLayer layoutDisplayLayer];
	}

	[super layoutSubviews];
}

// MARK: - Input

- (BOOL)canBecomeFirstResponder {
	return YES;
}

- (void)cancelPendingInput {
	[self.delayGestureRecognizer cancelDelayTimer];
	OSAppleTV *os = OSAppleTV::get_singleton();
	if (self.fallbackMenuJoyId >= 0 && os) {
		os->joy_button(self.fallbackMenuJoyId, JOY_BUTTON_1, false);
	}
	self.fallbackMenuJoyId = -1;
}

- (BOOL)sendAppleTVPress:(UIPress *)press pressed:(BOOL)pressed {
	if (press.type != UIPressTypeMenu) {
		return NO;
	}
	OSAppleTV *os = OSAppleTV::get_singleton();
	if (!os) {
		return NO;
	}
	if (!pressed && self.fallbackMenuJoyId >= 0) {
		// Always finish a press that we began, even if the game's Menu
		// override changed while this button was held.
		os->joy_button(self.fallbackMenuJoyId, JOY_BUTTON_1, false);
		self.fallbackMenuJoyId = -1;
		return YES;
	}
	if (!os->get_overrides_menu_button() || os->has_remote_menu_handler()) {
		return NO;
	}
	int joy_id = os->get_remote_joy_id();
	if (joy_id < 0) {
		return NO;
	}
	// The native micro.buttonMenu handler owns normal Siri Remote input.
	// This fallback only applies when an unambiguous registered remote has
	// no native Menu element. Never invent an input device with ID zero.
	if (pressed) {
		self.fallbackMenuJoyId = joy_id;
	}
	os->joy_button(joy_id, JOY_BUTTON_1, pressed);
	return YES;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	NSMutableSet<UIPress *> *unhandled = [presses mutableCopy];
	for (UIPress *press in presses) {
		if ([self sendAppleTVPress:press pressed:YES]) {
			[unhandled removeObject:press];
		}
	}
	if (unhandled.count > 0) {
		[super pressesBegan:unhandled withEvent:event];
	}
}

- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	NSMutableSet<UIPress *> *unhandled = [presses mutableCopy];
	for (UIPress *press in presses) {
		if (press.type == UIPressTypeMenu && self.fallbackMenuJoyId >= 0) {
			[unhandled removeObject:press];
		}
	}
	if (unhandled.count > 0) {
		[super pressesChanged:unhandled withEvent:event];
	}
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	NSMutableSet<UIPress *> *unhandled = [presses mutableCopy];
	for (UIPress *press in presses) {
		if ([self sendAppleTVPress:press pressed:NO]) {
			[unhandled removeObject:press];
		}
	}
	if (unhandled.count > 0) {
		[super pressesEnded:unhandled withEvent:event];
	}
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	NSMutableSet<UIPress *> *unhandled = [presses mutableCopy];
	for (UIPress *press in presses) {
		if ([self sendAppleTVPress:press pressed:NO]) {
			[unhandled removeObject:press];
		}
	}
	if (unhandled.count > 0) {
		[super pressesCancelled:unhandled withEvent:event];
	}
}

@end
