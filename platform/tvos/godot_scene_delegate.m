/**************************************************************************/
/*  godot_scene_delegate.m                                                */
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

#import "godot_scene_delegate.h"

#import "app_delegate.h"
#import "godot_app_delegate.h"

@interface SceneDelegate ()

+ (void)connectService:(SceneDelegateService *)service replayLifecycle:(BOOL)replayLifecycle;
+ (NSArray<SceneDelegateService *> *)connectedServices;
- (void)forwardLegacyURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts;
- (void)forwardLegacyUserActivity:(NSUserActivity *)userActivity;
- (void)forwardLegacyConnectionOptions;
- (void)replayLegacyLifecycle;
- (void)deliverURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts;
- (void)deliverUserActivity:(NSUserActivity *)userActivity;
- (void)flushPendingEvents;

@end

@implementation SceneDelegate

static NSMutableArray<SceneDelegateService *> *services = nil;
static NSMutableSet<SceneDelegateService *> *initializedServices = nil;
static NSMutableArray<NSDictionary *> *pendingEvents = nil;
static __weak UIScene *connectedScene = nil;
static __weak SceneDelegate *connectedDelegate = nil;
static BOOL engineInitialized = NO;
static BOOL deliveredLegacyConnectionOptions = NO;
static BOOL flushingPendingEvents = NO;
static BOOL deliveringInitialState = NO;
static UISceneSession *connectedSession = nil;
static UISceneConnectionOptions *connectionOptions = nil;

+ (NSArray<SceneDelegateService *> *)services {
	return [services copy];
}

+ (NSArray<SceneDelegateService *> *)connectedServices {
	NSMutableArray<SceneDelegateService *> *result = [NSMutableArray array];
	for (SceneDelegateService *service in [services copy]) {
		if ([initializedServices containsObject:service]) {
			[result addObject:service];
		}
	}
	return result;
}

+ (void)load {
	services = [NSMutableArray new];
	initializedServices = [NSMutableSet new];
	pendingEvents = [NSMutableArray new];
	[services addObject:[AppDelegate getSingleton]];
}

+ (void)connectService:(SceneDelegateService *)service replayLifecycle:(BOOL)replayLifecycle {
	UIScene *scene = connectedScene;
	if (!scene || [initializedServices containsObject:service]) {
		return;
	}
	// The engine's own service must create its window before the first frame.
	// External plugins may emit Godot signals from willConnectToSession, so
	// register_platform_apis() in setup2 is too early to deliver their options.
	if (!engineInitialized && service != [AppDelegate getSingleton]) {
		return;
	}
	[initializedServices addObject:service];
	if ([service respondsToSelector:@selector(scene:willConnectToSession:options:)]) {
		[service scene:scene willConnectToSession:connectedSession options:connectionOptions];
	}
	if (!replayLifecycle || connectedScene != scene) {
		return;
	}
	if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) {
		if ([service respondsToSelector:@selector(sceneWillEnterForeground:)]) {
			[service sceneWillEnterForeground:scene];
		}
		if (scene.activationState == UISceneActivationStateForegroundActive && [service respondsToSelector:@selector(sceneDidBecomeActive:)]) {
			[service sceneDidBecomeActive:scene];
		}
	} else if (scene.activationState == UISceneActivationStateBackground && [service respondsToSelector:@selector(sceneDidEnterBackground:)]) {
		[service sceneDidEnterBackground:scene];
	}
}

+ (void)addService:(SceneDelegateService *)service {
	if (!service || [services containsObject:service]) {
		return;
	}
	[services addObject:service];
	[self connectService:service replayLifecycle:YES];
}

+ (void)completeEngineInitialization {
	if (engineInitialized) {
		return;
	}
	// Called only after Main::start() returned true and OS::set_main_loop()
	// synchronously ran MainLoop::init(). This does not wait for user scripts'
	// asynchronous/deferred initialization after their initial _ready callback.
	deliveringInitialState = YES;
	engineInitialized = YES;
	for (SceneDelegateService *service in [services copy]) {
		[self connectService:service replayLifecycle:YES];
	}
	[connectedDelegate replayLegacyLifecycle];
	[connectedDelegate forwardLegacyConnectionOptions];
	deliveringInitialState = NO;
	[connectedDelegate flushPendingEvents];
}

- (UIWindow *)window {
	return [AppDelegate getSingleton].window;
}

- (void)setWindow:(UIWindow *)window {
	[AppDelegate getSingleton].window = window;
}

- (void)forwardLegacyURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		// Services registered for scenes receive their own connection options
		// and warm scene callbacks, never a duplicate application callback.
		if ([services containsObject:service] || ![service respondsToSelector:@selector(application:openURL:options:)]) {
			continue;
		}
		for (UIOpenURLContext *context in URLContexts) {
			NSMutableDictionary *options = [NSMutableDictionary dictionary];
			if (context.options.sourceApplication) {
				options[UIApplicationOpenURLOptionsSourceApplicationKey] = context.options.sourceApplication;
			}
			if (context.options.annotation) {
				options[UIApplicationOpenURLOptionsAnnotationKey] = context.options.annotation;
			}
			[service application:[UIApplication sharedApplication] openURL:context.URL options:options];
		}
	}
}

- (void)forwardLegacyUserActivity:(NSUserActivity *)userActivity {
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		if ([services containsObject:service] || ![service respondsToSelector:@selector(application:continueUserActivity:restorationHandler:)]) {
			continue;
		}
		[service application:[UIApplication sharedApplication]
				continueUserActivity:userActivity
				  restorationHandler:^(NSArray<id<UIUserActivityRestoring>> *objects){
						  // Godot restores its own existing game view.
				  }];
	}
}

- (void)forwardLegacyConnectionOptions {
	if (!engineInitialized || deliveredLegacyConnectionOptions || !connectedScene) {
		return;
	}
	deliveredLegacyConnectionOptions = YES;
	[self forwardLegacyURLContexts:connectionOptions.URLContexts];
	for (NSUserActivity *activity in connectionOptions.userActivities) {
		[self forwardLegacyUserActivity:activity];
	}
}

- (void)replayLegacyLifecycle {
	UIScene *scene = connectedScene;
	if (!scene) {
		return;
	}
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		if ([services containsObject:service]) {
			continue;
		}
		if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) {
			if ([service respondsToSelector:@selector(applicationWillEnterForeground:)]) {
				[service applicationWillEnterForeground:[UIApplication sharedApplication]];
			}
			if (scene.activationState == UISceneActivationStateForegroundActive && [service respondsToSelector:@selector(applicationDidBecomeActive:)]) {
				[service applicationDidBecomeActive:[UIApplication sharedApplication]];
			}
		} else if (scene.activationState == UISceneActivationStateBackground && [service respondsToSelector:@selector(applicationDidEnterBackground:)]) {
			[service applicationDidEnterBackground:[UIApplication sharedApplication]];
		}
	}
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
	if (![scene isKindOfClass:[UIWindowScene class]] || connectedScene) {
		return;
	}
	connectedScene = scene;
	connectedDelegate = self;
	connectedSession = session;
	connectionOptions = options;
	deliveredLegacyConnectionOptions = NO;
	[initializedServices removeAllObjects];

	deliveringInitialState = YES;
	for (SceneDelegateService *service in [services copy]) {
		[SceneDelegate connectService:service replayLifecycle:NO];
	}
	[self forwardLegacyConnectionOptions];
	deliveringInitialState = NO;
	[self flushPendingEvents];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
	if (connectedScene != scene) {
		return;
	}
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:_cmd]) {
			[service sceneDidDisconnect:scene];
		}
	}
	[initializedServices removeAllObjects];
	[pendingEvents removeAllObjects];
	connectedScene = nil;
	connectedDelegate = nil;
	connectedSession = nil;
	connectionOptions = nil;
	deliveredLegacyConnectionOptions = NO;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
	if (connectedScene != scene) {
		return;
	}
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:_cmd]) {
			[service sceneDidBecomeActive:scene];
		}
	}
	if (!engineInitialized) {
		return;
	}
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		if (![services containsObject:service] && [service respondsToSelector:@selector(applicationDidBecomeActive:)]) {
			[service applicationDidBecomeActive:[UIApplication sharedApplication]];
		}
	}
}

- (void)sceneWillResignActive:(UIScene *)scene {
	if (connectedScene != scene) {
		return;
	}
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:_cmd]) {
			[service sceneWillResignActive:scene];
		}
	}
	if (!engineInitialized) {
		return;
	}
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		if (![services containsObject:service] && [service respondsToSelector:@selector(applicationWillResignActive:)]) {
			[service applicationWillResignActive:[UIApplication sharedApplication]];
		}
	}
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
	if (connectedScene != scene) {
		return;
	}
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:_cmd]) {
			[service sceneDidEnterBackground:scene];
		}
	}
	if (!engineInitialized) {
		return;
	}
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		if (![services containsObject:service] && [service respondsToSelector:@selector(applicationDidEnterBackground:)]) {
			[service applicationDidEnterBackground:[UIApplication sharedApplication]];
		}
	}
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
	if (connectedScene != scene) {
		return;
	}
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:_cmd]) {
			[service sceneWillEnterForeground:scene];
		}
	}
	if (!engineInitialized) {
		return;
	}
	for (ApplicationDelegateService *service in [GodotApplicalitionDelegate services]) {
		if (![services containsObject:service] && [service respondsToSelector:@selector(applicationWillEnterForeground:)]) {
			[service applicationWillEnterForeground:[UIApplication sharedApplication]];
		}
	}
}

- (void)deliverURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
	UIScene *scene = connectedScene;
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:@selector(scene:openURLContexts:)]) {
			[service scene:scene openURLContexts:URLContexts];
		}
	}
	[self forwardLegacyURLContexts:URLContexts];
}

- (void)deliverUserActivity:(NSUserActivity *)userActivity {
	UIScene *scene = connectedScene;
	for (SceneDelegateService *service in [SceneDelegate connectedServices]) {
		if ([service respondsToSelector:@selector(scene:continueUserActivity:)]) {
			[service scene:scene continueUserActivity:userActivity];
		}
	}
	[self forwardLegacyUserActivity:userActivity];
}

- (void)flushPendingEvents {
	if (!engineInitialized || deliveringInitialState || flushingPendingEvents) {
		return;
	}
	flushingPendingEvents = YES;
	while (pendingEvents.count > 0 && connectedScene) {
		NSDictionary *event = pendingEvents.firstObject;
		[pendingEvents removeObjectAtIndex:0];
		if (event[@"URLContexts"]) {
			[self deliverURLContexts:event[@"URLContexts"]];
		} else {
			[self deliverUserActivity:event[@"userActivity"]];
		}
	}
	flushingPendingEvents = NO;
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
	if (connectedScene != scene) {
		return;
	}
	// The queue is only for warm callbacks, not connectionOptions: cold URLs
	// arrive once via willConnect (scene plugins) or the legacy bridge above.
	[pendingEvents addObject:@{ @"URLContexts" : [URLContexts copy] }];
	[self flushPendingEvents];
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
	if (connectedScene != scene) {
		return;
	}
	[pendingEvents addObject:@{ @"userActivity" : userActivity }];
	[self flushPendingEvents];
}

@end
