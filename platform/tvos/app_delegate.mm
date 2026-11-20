/**************************************************************************/
/*  app_delegate.mm                                                       */
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

#import "app_delegate.h"

#include "core/project_settings.h"
#import "godot_view.h"
#include "main/main.h"
#include "os_appletv.h"
#import "view_controller.h"

#import <AVFoundation/AVFoundation.h>

static const NSTimeInterval kRenderingInterval = 1.0 / 60.0;

extern int gargc;
extern char **gargv;
extern int appletv_main(int, char **, String, String);
extern void appletv_finish();

@interface AppDelegate ()

@property(assign, nonatomic) BOOL engineInitialized;
@property(assign, nonatomic) BOOL usesSceneLifecycle;
@property(assign, nonatomic) BOOL sceneActive;
@property(assign, nonatomic) BOOL audioInterrupted;

@end

@implementation AppDelegate

static ViewController *mainViewController = nil;
static AppDelegate *delegateSingleton = nil;

+ (ViewController *)viewController {
	return mainViewController;
}

+ (AppDelegate *)getSingleton {
	if (!delegateSingleton) {
		delegateSingleton = [AppDelegate new];
	}
	return delegateSingleton;
}

- (void)attachViewController {
	// Keep one engine, renderer and GL context even if UIKit reconnects its scene.
	// Creating a second renderer would run Main::setup2() and Main::start() again.
	if (!mainViewController) {
		mainViewController = [[ViewController alloc] init];
		mainViewController.godotView.useCADisplayLink = bool(GLOBAL_DEF("display.tvOS/use_cadisplaylink", true)) ? YES : NO;
		mainViewController.godotView.renderingInterval = kRenderingInterval;
	}
	self.window.rootViewController = mainViewController;
	[self.window makeKeyAndVisible];
}

- (void)updateFocus {
	if (!self.engineInitialized || !OSAppleTV::get_singleton()) {
		return;
	}
	// Audio availability must never suspend the foreground game loop.
	OSAppleTV::get_singleton()->set_audio_enabled(self.sceneActive && !self.audioInterrupted && self.window);
	if (self.sceneActive && self.window) {
		OSAppleTV::get_singleton()->on_focus_in();
	} else {
		OSAppleTV::get_singleton()->on_focus_out();
	}
}

- (void)activateAudioSession {
	if (!self.sceneActive || !self.window) {
		return;
	}
	NSError *error = nil;
	BOOL activated = [[AVAudioSession sharedInstance] setActive:YES error:&error];
	self.audioInterrupted = !activated;
	if (!activated) {
		NSLog(@"Unable to reactivate the tvOS audio session: %@", error);
	}
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	if (self.engineInitialized) {
		return YES;
	}

	// tvOS has no persistent Documents directory. Preserve the port's user:// location.
	NSString *cacheDirectory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
	if (!cacheDirectory) {
		NSLog(@"Unable to locate the tvOS cache directory.");
		return NO;
	}

	String cachePath = String::utf8(cacheDirectory.UTF8String);
	int err = appletv_main(gargc, gargv, cachePath, cachePath);
	if (err != 0) {
		NSLog(@"Unable to initialize Godot (error %d).", err);
		return NO;
	}
	self.engineInitialized = YES;

	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(onAudioInterruption:)
												 name:AVAudioSessionInterruptionNotification
											   object:[AVAudioSession sharedInstance]];

	// Ambient permits other apps' background audio and is supported on tvOS.
	[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
	OSAppleTV::get_singleton()->set_keep_screen_on(bool(GLOBAL_DEF("display/window/energy_saving/keep_screen_on", true)));

	self.usesSceneLifecycle = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"] != nil;
	if (!self.usesSceneLifecycle) {
		// Compatibility for existing Xcode wrappers which have not added the scene manifest.
		self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
		[self attachViewController];
	}
	return YES;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
	if (!self.engineInitialized || ![scene isKindOfClass:[UIWindowScene class]]) {
		return;
	}
	if (self.window && self.window.windowScene != scene) {
		NSLog(@"Godot supports a single tvOS window scene.");
		return;
	}

	self.usesSceneLifecycle = YES;
	if (!self.window) {
		self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
		[self attachViewController];
	}
}

- (BOOL)isGameScene:(UIScene *)scene {
	return self.window && self.window.windowScene == scene;
}

- (void)sceneDidDisconnect:(UIScene *)scene {
	if (![self isGameScene:scene]) {
		return;
	}
	self.sceneActive = NO;
	[self updateFocus];
	OSAppleTV::get_singleton()->on_enter_background();
	self.window.hidden = YES;
	self.window.rootViewController = nil;
	self.window = nil;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
	if ([self isGameScene:scene]) {
		self.sceneActive = YES;
		// An interruption need not have a matching Ended notification.
		[self activateAudioSession];
		[self updateFocus];
	}
}

- (void)sceneWillResignActive:(UIScene *)scene {
	if ([self isGameScene:scene]) {
		self.sceneActive = NO;
		[self updateFocus];
	}
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
	if ([self isGameScene:scene]) {
		self.sceneActive = NO;
		[self updateFocus];
		OSAppleTV::get_singleton()->on_enter_background();
	}
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
	if ([self isGameScene:scene]) {
		// Rendering and audio resume only after sceneDidBecomeActive.
		[mainViewController.view setNeedsLayout];
		OSAppleTV::get_singleton()->on_exit_background();
	}
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	if (!self.usesSceneLifecycle) {
		self.sceneActive = YES;
		[self activateAudioSession];
		[self updateFocus];
	}
}

- (void)applicationWillResignActive:(UIApplication *)application {
	if (!self.usesSceneLifecycle) {
		self.sceneActive = NO;
		[self updateFocus];
	}
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	if (!self.usesSceneLifecycle && self.engineInitialized) {
		self.sceneActive = NO;
		[self updateFocus];
		OSAppleTV::get_singleton()->on_enter_background();
	}
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	if (!self.usesSceneLifecycle && self.engineInitialized) {
		OSAppleTV::get_singleton()->on_exit_background();
	}
}

- (void)onAudioInterruption:(NSNotification *)notification {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self onAudioInterruption:notification];
		});
		return;
	}
	NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
	if (!type) {
		return;
	}
	if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
		self.audioInterrupted = YES;
		[self updateFocus];
		// Suspension notifications may arrive only after the app is active again.
		if ([notification.userInfo[AVAudioSessionInterruptionWasSuspendedKey] boolValue]) {
			[self activateAudioSession];
		}
	} else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
		self.audioInterrupted = NO;
		[self activateAudioSession];
	} else {
		return;
	}
	// Background callbacks only update audio intent; they never restart GL/audio.
	[self updateFocus];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
	if (self.engineInitialized && OS::get_singleton()->get_main_loop()) {
		OS::get_singleton()->get_main_loop()->notification(MainLoop::NOTIFICATION_OS_MEMORY_WARNING);
	}
}

- (void)applicationWillTerminate:(UIApplication *)application {
	if (!self.engineInitialized) {
		return;
	}
	self.sceneActive = NO;
	[self updateFocus];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	appletv_finish();
	self.engineInitialized = NO;
	self.window.rootViewController = nil;
	self.window = nil;
	mainViewController = nil;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
