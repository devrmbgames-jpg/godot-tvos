/**************************************************************************/
/*  joypad_appletv.mm                                                     */
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

#import "joypad_appletv.h"

#import "app_delegate.h"
#import "godot_view.h"
#import "view_controller.h"

#include "os_appletv.h"

#ifndef JOYPAD_APPLETV_INPUT_LOG_ENABLED
#define JOYPAD_APPLETV_INPUT_LOG_ENABLED 0
#endif

#if JOYPAD_APPLETV_INPUT_LOG_ENABLED
#define JOYPAD_APPLETV_LOG(format, ...) NSLog(@"[JoypadAppleTV] " format, ##__VA_ARGS__)
#else
#define JOYPAD_APPLETV_LOG(format, ...) \
	do {                                \
	} while (0)
#endif

// Godot 3.6 has no JOY_ANALOG_DPAD_X/Y constants. These unused axes keep a
// physical D-Pad independent of both sticks (0..3) and the triggers (6..7).
static const int APPLETV_DPAD_AXIS_X = JOY_AXIS_4;
static const int APPLETV_DPAD_AXIS_Y = JOY_AXIS_5;
static const int APPLETV_REMOTE_TOUCH_BUTTON = JOY_BUTTON_5;

typedef NS_OPTIONS(NSUInteger, AppleTVRemoteTouchSource) {
	AppleTVRemoteTouchSourceNative = 1 << 0,
	AppleTVRemoteTouchSourceButton = 1 << 1,
	AppleTVRemoteTouchSourceUIKit = 1 << 2,
};

@protocol JoypadAppleTVIndirectTouchReceiver <NSObject>
- (void)joypadIndirectTouchBegan;
- (void)joypadIndirectTouchEnded;
@end

// A best-effort fallback for profiles which expose no native contact state.
// It does not cancel/delay UIKit input or arbitrate other recognizers.
@interface JoypadAppleTVIndirectTouchRecognizer : UIGestureRecognizer
@property(weak, nonatomic) id<JoypadAppleTVIndirectTouchReceiver> touchReceiver;
@property(strong, nonatomic) NSMutableSet<UITouch *> *activeIndirectTouches;
- (instancetype)initWithTouchReceiver:(id<JoypadAppleTVIndirectTouchReceiver>)receiver;
@end

@implementation JoypadAppleTVIndirectTouchRecognizer
- (instancetype)initWithTouchReceiver:(id<JoypadAppleTVIndirectTouchReceiver>)receiver {
	self = [super initWithTarget:nil action:nil];
	if (self) {
		self.touchReceiver = receiver;
		self.activeIndirectTouches = [NSMutableSet set];
		self.cancelsTouchesInView = NO;
		self.delaysTouchesBegan = NO;
		self.delaysTouchesEnded = NO;
		self.allowedTouchTypes = @[ @(UITouchTypeIndirect) ];
		self.allowedPressTypes = @[];
	}
	return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	BOOL was_empty = self.activeIndirectTouches.count == 0;
	for (UITouch *touch in touches) {
		if (touch.type == UITouchTypeIndirect) {
			[self.activeIndirectTouches addObject:touch];
		}
	}
	if (was_empty && self.activeIndirectTouches.count > 0) {
		self.state = UIGestureRecognizerStateBegan;
		[self.touchReceiver joypadIndirectTouchBegan];
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (self.activeIndirectTouches.count > 0) {
		self.state = UIGestureRecognizerStateChanged;
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	BOOL had_touch = self.activeIndirectTouches.count > 0;
	[self.activeIndirectTouches minusSet:touches];
	if (had_touch && self.activeIndirectTouches.count == 0) {
		[self.touchReceiver joypadIndirectTouchEnded];
		self.state = UIGestureRecognizerStateEnded;
	}
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (self.activeIndirectTouches.count > 0) {
		[self.activeIndirectTouches removeAllObjects];
		[self.touchReceiver joypadIndirectTouchEnded];
	}
	self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
	if (self.activeIndirectTouches.count > 0) {
		[self.activeIndirectTouches removeAllObjects];
		[self.touchReceiver joypadIndirectTouchEnded];
	}
	[super reset];
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)recognizer {
	return NO;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)recognizer {
	return NO;
}
@end

@interface JoypadAppleTVObserver () <JoypadAppleTVIndirectTouchReceiver>
@property(assign, nonatomic) BOOL isObserving;
@property(assign, nonatomic) BOOL isProcessing;
@property(assign, nonatomic) BOOL inputActive;
@property(assign, nonatomic) BOOL nativeUIInput;
@property(assign, nonatomic) BOOL menuButtonEnabled;
@property(strong, nonatomic) NSMutableDictionary<NSNumber *, GCController *> *connectedJoypads;
@property(strong, nonatomic) NSMutableArray<GCController *> *joypadsQueue;
@property(strong, nonatomic) NSMutableSet<GCController *> *controllersWithNativeTouchpad;
@property(strong, nonatomic) NSMapTable<GCController *, NSNumber *> *remoteTouchSources;
@property(strong, nonatomic) JoypadAppleTVIndirectTouchRecognizer *indirectTouchRecognizer;
@property(weak, nonatomic) UIWindow *indirectTouchWindow;
@property(weak, nonatomic) GCController *indirectTouchController;

- (int)getJoyIdForController:(GCController *)controller;
- (int)getJoyIdForControllerName:(NSString *)name;
- (int)getRemoteJoyId;
- (BOOL)hasRemoteMenuHandler;
- (void)setInputActive:(BOOL)active;
- (void)setNativeUIInput:(BOOL)active;
- (void)setMenuButtonEnabled:(BOOL)enabled;
- (void)installIndirectTouchFallback;
- (void)removeIndirectTouchFallback;
- (void)resetController:(GCController *)controller;
- (void)clearControllerHandlers:(GCController *)controller;
- (void)configureController:(GCController *)controller;
@end

JoypadAppleTV::JoypadAppleTV() {
	observer = [[JoypadAppleTVObserver alloc] init];
	[observer startObserving];
}

JoypadAppleTV::~JoypadAppleTV() {
	[observer finishObserving];
	observer = nil;
}

void JoypadAppleTV::start_processing() { [observer startProcessing]; }
void JoypadAppleTV::set_input_active(bool p_active) { [observer setInputActive:p_active]; }
void JoypadAppleTV::set_native_ui_input(bool p_active) { [observer setNativeUIInput:p_active]; }
void JoypadAppleTV::set_menu_button_enabled(bool p_enabled) { [observer setMenuButtonEnabled:p_enabled]; }
int JoypadAppleTV::get_remote_joy_id() const { return observer ? [observer getRemoteJoyId] : -1; }
bool JoypadAppleTV::has_remote_menu_handler() const { return observer && [observer hasRemoteMenuHandler]; }

int JoypadAppleTV::joy_id_for_name(const String &p_name) {
	if (!observer) {
		return -1;
	}
	return [observer getJoyIdForControllerName:[NSString stringWithUTF8String:p_name.utf8().get_data()]];
}

@implementation JoypadAppleTVObserver

- (instancetype)init {
	self = [super init];
	if (self) {
		self.connectedJoypads = [NSMutableDictionary dictionary];
		self.joypadsQueue = [NSMutableArray array];
		self.controllersWithNativeTouchpad = [NSMutableSet set];
		self.remoteTouchSources = [NSMapTable strongToStrongObjectsMapTable];
	}
	return self;
}

- (BOOL)canSendInput {
	return self.isProcessing && self.inputActive && !self.nativeUIInput && OSAppleTV::get_singleton();
}

- (int)getJoyIdForController:(GCController *)controller {
	if (!controller) {
		return -1;
	}
	NSNumber *key = [self.connectedJoypads allKeysForObject:controller].firstObject;
	return key ? key.intValue : -1;
}

- (int)getJoyIdForControllerName:(NSString *)name {
	for (NSNumber *key in [self.connectedJoypads.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
		if ([self.connectedJoypads[key].vendorName containsString:name]) {
			return key.intValue;
		}
	}
	return -1;
}

- (int)getRemoteJoyId {
	int result = -1;
	for (NSNumber *key in self.connectedJoypads) {
		GCController *controller = self.connectedJoypads[key];
		if (controller.microGamepad && !controller.extendedGamepad) {
			// UIKit does not identify the originating controller. Never route an
			// ambiguous press to an arbitrary player's device (or device zero).
			if (result >= 0) {
				return -1;
			}
			result = key.intValue;
		}
	}
	return result;
}

- (BOOL)hasRemoteMenuHandler {
	for (GCController *controller in self.connectedJoypads.allValues) {
		if (controller.microGamepad && !controller.extendedGamepad && controller.microGamepad.buttonMenu) {
			return YES;
		}
	}
	return NO;
}

- (void)sendButton:(int)button pressed:(BOOL)pressed controller:(GCController *)controller {
	if (![self canSendInput]) {
		return;
	}
	int joy_id = [self getJoyIdForController:controller];
	if (joy_id >= 0) {
		JOYPAD_APPLETV_LOG(@"button joy=%d index=%d pressed=%d", joy_id, button, (int)pressed);
		OSAppleTV::get_singleton()->joy_button(joy_id, button, pressed);
	}
}

- (void)sendAxis:(int)axis value:(float)value controller:(GCController *)controller {
	if (![self canSendInput]) {
		return;
	}
	int joy_id = [self getJoyIdForController:controller];
	if (joy_id >= 0) {
		JOYPAD_APPLETV_LOG(@"axis joy=%d index=%d value=%+.4f", joy_id, axis, value);
		OSAppleTV::get_singleton()->joy_axis(joy_id, axis, value);
	}
}

- (void)resetController:(GCController *)controller {
	int joy_id = [self getJoyIdForController:controller];
	OSAppleTV *os = OSAppleTV::get_singleton();
	if (joy_id >= 0 && os) {
		// Send releases before disconnecting: Godot's connection callback
		// clears raw state but does not release InputMap actions on its own.
		for (int button = 0; button < JOY_BUTTON_MAX; button++) {
			os->joy_button(joy_id, button, false);
		}
		for (int axis = 0; axis < JOY_AXIS_MAX; axis++) {
			os->joy_axis(joy_id, axis, 0.0f);
		}
	}
	[self.remoteTouchSources removeObjectForKey:controller];
}

- (void)resetInput {
	for (GCController *controller in self.connectedJoypads.allValues) {
		[self resetController:controller];
	}
	self.indirectTouchRecognizer.enabled = NO;
	self.indirectTouchRecognizer.enabled = [self canSendInput];
	self.indirectTouchController = nil;
}

- (void)updateMenuPolicy {
	for (GCController *controller in self.connectedJoypads.allValues) {
		if (controller.microGamepad && !controller.extendedGamepad) {
			// Menu belongs to tvOS unless the game explicitly overrides it.
			GCControllerButtonInput *menu = controller.microGamepad.buttonMenu;
			BOOL enabled = [self canSendInput] && self.menuButtonEnabled;
			menu.preferredSystemGestureState = enabled ? GCSystemGestureStateDisabled : GCSystemGestureStateEnabled;
			if (!enabled) {
				menu.pressedChangedHandler = nil;
				continue;
			}
			_weakify(self);
			_weakify(controller);
			menu.pressedChangedHandler = ^(GCControllerButtonInput *input, float value, BOOL pressed) {
				_strongify(self);
				_strongify(controller);
				if (self.menuButtonEnabled) {
					[self sendButton:JOY_BUTTON_1 pressed:pressed controller:controller];
				}
			};
		}
	}
}

- (void)setInputActive:(BOOL)active {
	if (self.inputActive != active) {
		_inputActive = active;
		if (!active) {
			[self resetInput];
		}
	}
	[self updateMenuPolicy];
	if (active) {
		[self installIndirectTouchFallback];
	}
	self.indirectTouchRecognizer.enabled = [self canSendInput];
}

- (void)setNativeUIInput:(BOOL)active {
	if (self.nativeUIInput != active) {
		_nativeUIInput = active;
		if (active) {
			[self resetInput];
		}
	}
	[self updateMenuPolicy];
	self.indirectTouchRecognizer.enabled = [self canSendInput];
}

- (void)setMenuButtonEnabled:(BOOL)enabled {
	_menuButtonEnabled = enabled;
	if (!enabled && OSAppleTV::get_singleton()) {
		for (NSNumber *key in self.connectedJoypads) {
			GCController *controller = self.connectedJoypads[key];
			if (controller.microGamepad && !controller.extendedGamepad) {
				OSAppleTV::get_singleton()->joy_button(key.intValue, JOY_BUTTON_1, false);
			}
		}
	}
	[self updateMenuPolicy];
}

- (void)startObserving {
	if (self.isObserving) {
		return;
	}
	self.isObserving = YES;
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerWasConnected:) name:GCControllerDidConnectNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerWasDisconnected:) name:GCControllerDidDisconnectNotification object:nil];
	for (GCController *controller in GCController.controllers) {
		[self connectController:controller];
	}
}

- (void)startProcessing {
	if (self.isProcessing) {
		return;
	}
	self.isProcessing = YES;
	for (GCController *controller in [self.joypadsQueue copy]) {
		[self connectController:controller];
	}
	[self.joypadsQueue removeAllObjects];
	[self installIndirectTouchFallback];
}

- (void)finishObserving {
	if (!self.isObserving) {
		return;
	}
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	self.isObserving = NO;
	[self setInputActive:NO];
	for (GCController *controller in self.connectedJoypads.allValues) {
		[self clearControllerHandlers:controller];
	}
	self.isProcessing = NO;
	[self removeIndirectTouchFallback];
	[self.connectedJoypads removeAllObjects];
	[self.joypadsQueue removeAllObjects];
	[self.controllersWithNativeTouchpad removeAllObjects];
	[self.remoteTouchSources removeAllObjects];
}

- (void)dealloc {
	[self finishObserving];
}

- (GCControllerPlayerIndex)freePlayerIndex {
	for (NSInteger player = GCControllerPlayerIndex1; player <= GCControllerPlayerIndex4; player++) {
		BOOL in_use = NO;
		for (GCController *controller in self.connectedJoypads.allValues) {
			if (controller.playerIndex == player) {
				in_use = YES;
				break;
			}
		}
		if (!in_use) {
			return (GCControllerPlayerIndex)player;
		}
	}
	return GCControllerPlayerIndexUnset;
}

- (void)connectController:(GCController *)controller {
	if (!self.isObserving || !controller || [self getJoyIdForController:controller] >= 0) {
		return;
	}
	if (!self.isProcessing) {
		if (![self.joypadsQueue containsObject:controller]) {
			[self.joypadsQueue addObject:controller];
		}
		return;
	}
	if (!controller.extendedGamepad && !controller.microGamepad) {
		return;
	}
	OSAppleTV *os = OSAppleTV::get_singleton();
	int joy_id = os ? os->get_unused_joy_id() : -1;
	if (joy_id < 0) {
		return;
	}
	controller.handlerQueue = dispatch_get_main_queue();
	if (controller.playerIndex == GCControllerPlayerIndexUnset) {
		controller.playerIndex = [self freePlayerIndex];
	}
	self.connectedJoypads[@(joy_id)] = controller;
	NSString *name = controller.vendorName ?: @"Apple TV Controller";
	os->joy_connection_changed(joy_id, true, String::utf8(name.UTF8String));
	[self configureController:controller];
	[self updateMenuPolicy];
	[self installIndirectTouchFallback];
	JOYPAD_APPLETV_LOG(@"connected joy=%d name=%@", joy_id, name);
}

- (void)controllerWasConnected:(NSNotification *)notification {
	GCController *controller = notification.object;
	if (![NSThread isMainThread]) {
		_weakify(self);
		dispatch_async(dispatch_get_main_queue(), ^{
			_strongify(self);
			[self connectController:controller];
		});
		return;
	}
	[self connectController:controller];
}

- (void)disconnectController:(GCController *)controller {
	if (!controller) {
		return;
	}
	[self.joypadsQueue removeObject:controller];
	int joy_id = [self getJoyIdForController:controller];
	if (joy_id >= 0) {
		[self resetController:controller];
		[self clearControllerHandlers:controller];
		if (OSAppleTV::get_singleton()) {
			OSAppleTV::get_singleton()->joy_connection_changed(joy_id, false, "");
		}
		[self.connectedJoypads removeObjectForKey:@(joy_id)];
	}
	[self.controllersWithNativeTouchpad removeObject:controller];
	[self.remoteTouchSources removeObjectForKey:controller];
	if (self.indirectTouchController == controller) {
		self.indirectTouchController = nil;
		self.indirectTouchRecognizer.enabled = NO;
		self.indirectTouchRecognizer.enabled = [self canSendInput];
	}
}

- (void)controllerWasDisconnected:(NSNotification *)notification {
	GCController *controller = notification.object;
	if (![NSThread isMainThread]) {
		_weakify(self);
		dispatch_async(dispatch_get_main_queue(), ^{
			_strongify(self);
			[self disconnectController:controller];
		});
		return;
	}
	[self disconnectController:controller];
}

- (void)clearControllerHandlers:(GCController *)controller {
	controller.controllerPausedHandler = nil;
	controller.extendedGamepad.valueChangedHandler = nil;
	controller.microGamepad.valueChangedHandler = nil;
	GCPhysicalInputProfile *profile = controller.physicalInputProfile;
	for (GCControllerButtonInput *button in profile.allButtons) {
		button.pressedChangedHandler = nil;
		button.valueChangedHandler = nil;
		button.touchedChangedHandler = nil;
	}
	for (GCControllerAxisInput *axis in profile.allAxes) {
		axis.valueChangedHandler = nil;
	}
	for (GCControllerDirectionPad *dpad in profile.allDpads) {
		dpad.valueChangedHandler = nil;
	}
	for (GCControllerTouchpad *touchpad in profile.allTouchpads) {
		touchpad.touchDown = nil;
		touchpad.touchMoved = nil;
		touchpad.touchUp = nil;
	}
	if (controller.microGamepad && !controller.extendedGamepad) {
		controller.microGamepad.buttonMenu.preferredSystemGestureState = GCSystemGestureStateEnabled;
	}
}

- (void)bindButton:(GCControllerButtonInput *)button index:(int)index controller:(GCController *)controller {
	_weakify(self);
	_weakify(controller);
	button.pressedChangedHandler = ^(GCControllerButtonInput *input, float value, BOOL pressed) {
		_strongify(self);
		_strongify(controller);
		[self sendButton:index pressed:pressed controller:controller];
	};
}

- (void)bindAxes:(GCControllerDirectionPad *)dpad xAxis:(int)x_axis yAxis:(int)y_axis controller:(GCController *)controller {
	_weakify(self);
	_weakify(controller);
	dpad.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x_value, float y_value) {
		_strongify(self);
		_strongify(controller);
		[self sendAxis:x_axis value:x_value controller:controller];
		[self sendAxis:y_axis value:-y_value controller:controller];
	};
}

- (void)bindDpadButtons:(GCControllerDirectionPad *)dpad controller:(GCController *)controller {
	[self bindButton:dpad.up index:JOY_DPAD_UP controller:controller];
	[self bindButton:dpad.down index:JOY_DPAD_DOWN controller:controller];
	[self bindButton:dpad.left index:JOY_DPAD_LEFT controller:controller];
	[self bindButton:dpad.right index:JOY_DPAD_RIGHT controller:controller];
}

- (void)bindTrigger:(GCControllerButtonInput *)trigger button:(int)button axis:(int)axis controller:(GCController *)controller {
	_weakify(self);
	_weakify(controller);
	trigger.valueChangedHandler = ^(GCControllerButtonInput *input, float value, BOOL pressed) {
		_strongify(self);
		_strongify(controller);
		[self sendButton:button pressed:pressed controller:controller];
		[self sendAxis:axis value:value controller:controller];
	};
}

- (void)configureController:(GCController *)controller {
	// Individual callbacks have exactly one owner; no profile callback forwards
	// a second copy of sticks, D-Pad or face-button events.
	[self clearControllerHandlers:controller];
	GCExtendedGamepad *gamepad = controller.extendedGamepad;
	if (gamepad) {
		[self bindAxes:gamepad.leftThumbstick xAxis:JOY_ANALOG_LX yAxis:JOY_ANALOG_LY controller:controller];
		[self bindAxes:gamepad.rightThumbstick xAxis:JOY_ANALOG_RX yAxis:JOY_ANALOG_RY controller:controller];
		[self bindAxes:gamepad.dpad xAxis:APPLETV_DPAD_AXIS_X yAxis:APPLETV_DPAD_AXIS_Y controller:controller];
		[self bindDpadButtons:gamepad.dpad controller:controller];
		[self bindButton:gamepad.buttonA index:JOY_BUTTON_0 controller:controller];
		[self bindButton:gamepad.buttonB index:JOY_BUTTON_1 controller:controller];
		[self bindButton:gamepad.buttonX index:JOY_BUTTON_2 controller:controller];
		[self bindButton:gamepad.buttonY index:JOY_BUTTON_3 controller:controller];
		[self bindButton:gamepad.leftShoulder index:JOY_L controller:controller];
		[self bindButton:gamepad.rightShoulder index:JOY_R controller:controller];
		[self bindTrigger:gamepad.leftTrigger button:JOY_L2 axis:JOY_ANALOG_L2 controller:controller];
		[self bindTrigger:gamepad.rightTrigger button:JOY_R2 axis:JOY_ANALOG_R2 controller:controller];
		[self bindButton:gamepad.leftThumbstickButton index:JOY_L3 controller:controller];
		[self bindButton:gamepad.rightThumbstickButton index:JOY_R3 controller:controller];
		[self bindButton:gamepad.buttonOptions index:JOY_SELECT controller:controller];
		[self bindButton:gamepad.buttonMenu index:JOY_START controller:controller];
		[self bindButton:gamepad.buttonHome index:JOY_GUIDE controller:controller];
		return;
	}

	GCMicroGamepad *micro = controller.microGamepad;
	if (!micro) {
		return;
	}
	micro.allowsRotation = NO;
	// Keep the original relative touch-surface behavior.
	[self bindAxes:micro.dpad xAxis:JOY_ANALOG_LX yAxis:JOY_ANALOG_LY controller:controller];

	GCControllerDirectionPad *cardinal = nil;
	GCControllerButtonInput *center = nil;
	if (@available(tvOS 15.0, *)) {
		cardinal = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad];
		center = controller.physicalInputProfile.buttons[GCInputDirectionalCenterButton];
	}
	[self bindDpadButtons:cardinal ?: micro.dpad controller:controller];
	if (center) {
		// buttonA covers the WHOLE clickpad, including the ring. Only the
		// named center button may emit A on 2nd/3rd generation Siri Remotes.
		[self bindButton:center index:JOY_BUTTON_0 controller:controller];
	} else {
		_weakify(self);
		_weakify(controller);
		micro.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *input, float value, BOOL pressed) {
			_strongify(self);
			_strongify(controller);
			GCControllerDirectionPad *ring = nil;
			if (@available(tvOS 14.5, *)) {
				ring = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad];
			}
			// Legacy profiles have no ring; their A stays an immediate press.
			// If a partial profile exposes a ring but no center, suppress its A.
			if (pressed && (ring.up.isPressed || ring.down.isPressed || ring.left.isPressed || ring.right.isPressed)) {
				return;
			}
			[self sendButton:JOY_BUTTON_0 pressed:pressed controller:controller];
		};
	}
	[self bindButton:micro.buttonX index:JOY_BUTTON_2 controller:controller];
	[self configureRemoteTouch:controller];
}

- (void)setRemoteTouch:(BOOL)active source:(AppleTVRemoteTouchSource)source controller:(GCController *)controller {
	if (!controller || ![self canSendInput] || [self getJoyIdForController:controller] < 0) {
		return;
	}
	NSUInteger old_sources = [self.remoteTouchSources objectForKey:controller].unsignedIntegerValue;
	NSUInteger sources = active ? old_sources | source : old_sources & ~source;
	[self.remoteTouchSources setObject:@(sources) forKey:controller];
	if ((old_sources != 0) != (sources != 0)) {
		[self sendButton:APPLETV_REMOTE_TOUCH_BUTTON pressed:sources != 0 controller:controller];
	}
	if (old_sources && !sources && controller.microGamepad.dpad.isAnalog) {
		// Some relative touch profiles retain their last vector after lift.
		[self sendAxis:JOY_ANALOG_LX value:0 controller:controller];
		[self sendAxis:JOY_ANALOG_LY value:0 controller:controller];
	}
}

- (void)configureRemoteTouch:(GCController *)controller {
	GCPhysicalInputProfile *profile = controller.physicalInputProfile;
	GCControllerTouchpad *touchpad = profile.touchpads[GCInputDirectionalDpad];
	if (!touchpad && profile.touchpads.count == 1) {
		touchpad = profile.touchpads.allValues.firstObject;
	}
	_weakify(self);
	_weakify(controller);
	if (touchpad) {
		[self.controllersWithNativeTouchpad addObject:controller];
		GCControllerTouchpadHandler down = ^(GCControllerTouchpad *pad, float x, float y, float value, BOOL pressed) {
			_strongify(self);
			_strongify(controller);
			[self setRemoteTouch:YES source:AppleTVRemoteTouchSourceNative controller:controller];
		};
		touchpad.touchDown = down;
		touchpad.touchMoved = down;
		touchpad.touchUp = ^(GCControllerTouchpad *pad, float x, float y, float value, BOOL pressed) {
			_strongify(self);
			_strongify(controller);
			[self setRemoteTouch:NO source:AppleTVRemoteTouchSourceNative controller:controller];
		};
	} else {
		// Capacitive contact is available on some micro profiles without a
		// GCControllerTouchpad. Do not infer contact from a nonzero axis: a
		// finger can rest at (0, 0), and direction values can outlive contact.
		controller.microGamepad.buttonA.touchedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed, BOOL touched) {
			_strongify(self);
			_strongify(controller);
			[self setRemoteTouch:touched source:AppleTVRemoteTouchSourceButton controller:controller];
		};
	}
}

- (void)installIndirectTouchFallback {
	if (!self.isObserving || !self.isProcessing) {
		return;
	}
	UIWindow *window = AppDelegate.viewController.godotView.window;
	if (self.indirectTouchRecognizer && self.indirectTouchWindow == window) {
		return;
	}
	[self removeIndirectTouchFallback];
	if (!window) {
		return;
	}
	self.indirectTouchRecognizer = [[JoypadAppleTVIndirectTouchRecognizer alloc] initWithTouchReceiver:self];
	self.indirectTouchRecognizer.enabled = [self canSendInput];
	self.indirectTouchWindow = window;
	[window addGestureRecognizer:self.indirectTouchRecognizer];
}

- (void)removeIndirectTouchFallback {
	self.indirectTouchRecognizer.enabled = NO;
	if (self.indirectTouchRecognizer) {
		[self.indirectTouchWindow removeGestureRecognizer:self.indirectTouchRecognizer];
	}
	self.indirectTouchRecognizer = nil;
	self.indirectTouchWindow = nil;
	self.indirectTouchController = nil;
}

- (void)joypadIndirectTouchBegan {
	if (![self canSendInput]) {
		return;
	}
	int joy_id = [self getRemoteJoyId];
	GCController *controller = joy_id >= 0 ? self.connectedJoypads[@(joy_id)] : nil;
	if (!controller || [self.controllersWithNativeTouchpad containsObject:controller]) {
		return;
	}
	self.indirectTouchController = controller;
	[self setRemoteTouch:YES source:AppleTVRemoteTouchSourceUIKit controller:controller];
}

- (void)joypadIndirectTouchEnded {
	[self setRemoteTouch:NO source:AppleTVRemoteTouchSourceUIKit controller:self.indirectTouchController];
	self.indirectTouchController = nil;
}

@end
