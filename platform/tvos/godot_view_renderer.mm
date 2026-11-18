/**************************************************************************/
/*  godot_view_renderer.mm                                                */
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

#import "godot_view_renderer.h"

#import "godot_scene_delegate.h"
#import "godot_view.h"

#include "core/os/keyboard.h"
#include "core/project_settings.h"
#include "main/main.h"
#include "os_appletv.h"
#include "servers/audio_server.h"

#import <AudioToolbox/AudioServices.h>
//#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

@interface GodotViewRenderer ()

@property(assign, nonatomic) BOOL hasFinishedProjectDataSetup;
@property(assign, nonatomic) BOOL hasStartedMain;
@property(assign, nonatomic) BOOL hasFinishedSetup;
@property(assign, nonatomic) BOOL hasInitializationFailed;

@end

@implementation GodotViewRenderer

- (BOOL)setupView:(UIView *)view {
	if (self.hasInitializationFailed) {
		[(GodotView *)view stopRendering];
		return YES;
	}
	if (self.hasFinishedSetup) {
		return NO;
	}

	if (!OS::get_singleton()) {
		exit(0);
	}

	if (!self.hasFinishedProjectDataSetup) {
		[self setupProjectData];
		return YES;
	}

	if (!self.hasStartedMain) {
		if (!OSAppleTV::get_singleton()->start()) {
			self.hasInitializationFailed = YES;
			[(GodotView *)view stopRendering];
			ERR_PRINT("Unable to start the Godot tvOS main loop.");
			return YES;
		}
		self.hasStartedMain = YES;
		// Main::start installs and initializes the main loop before returning.
		[SceneDelegate completeEngineInitialization];
		return YES;
	}

	self.hasFinishedSetup = YES;

	return NO;
}

- (void)setupProjectData {
	Error err = Main::setup2();
	if (err != OK) {
		self.hasInitializationFailed = YES;
		ERR_PRINT("Unable to complete Godot tvOS initialization.");
		return;
	}
	self.hasFinishedProjectDataSetup = YES;

	// this might be necessary before here
	NSDictionary *dict = [[NSBundle mainBundle] infoDictionary];
	for (NSString *key in dict) {
		NSObject *value = [dict objectForKey:key];
		String ukey = String::utf8([key UTF8String]);

		// we need a NSObject to Variant conversor

		if ([value isKindOfClass:[NSString class]]) {
			NSString *str = (NSString *)value;
			String uval = String::utf8([str UTF8String]);

			ProjectSettings::get_singleton()->set("Info.plist/" + ukey, uval);

		} else if ([value isKindOfClass:[NSNumber class]]) {
			NSNumber *n = (NSNumber *)value;
			double dval = [n doubleValue];

			ProjectSettings::get_singleton()->set("Info.plist/" + ukey, dval);
		};
	}
}

- (void)renderOnView:(UIView *)view {
	if (!OSAppleTV::get_singleton()) {
		return;
	}

	OSAppleTV::get_singleton()->iterate();
}

@end
