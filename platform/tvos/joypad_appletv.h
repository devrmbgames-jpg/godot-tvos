/**************************************************************************/
/*  joypad_appletv.h                                                      */
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

#ifndef JOYPAD_APPLETV_H
#define JOYPAD_APPLETV_H

#import <GameController/GameController.h>

class String;

@interface JoypadAppleTVObserver : NSObject

- (void)startObserving;
- (void)startProcessing;
- (void)finishObserving;

@end

class JoypadAppleTV {
private:
	JoypadAppleTVObserver *observer;

public:
	JoypadAppleTV();
	~JoypadAppleTV();

	void start_processing();
	void set_input_active(bool p_active);
	void set_native_ui_input(bool p_active);
	void set_menu_button_enabled(bool p_enabled);
	int get_remote_joy_id() const;
	bool has_remote_menu_handler() const;

	int joy_id_for_name(const String &p_name);
};

#endif // JOYPAD_APPLETV_H
