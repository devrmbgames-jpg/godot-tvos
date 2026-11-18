/**************************************************************************/
/*  keyboard_input_view.mm                                                */
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

#import "keyboard_input_view.h"

#include "core/os/keyboard.h"
#include "os_appletv.h"

@interface GodotKeyboardInputView () <UITextFieldDelegate>

@property(nonatomic, copy) NSString *previousText;
@property(nonatomic, assign) NSRange previousSelectedRange;

@end

@implementation GodotKeyboardInputView

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

- (void)godot_commonInit {
	self.hidden = YES;
	self.delegate = self;

	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(observeTextChange:)
												 name:UITextFieldTextDidChangeNotification
											   object:self];
}

- (void)setSelectedRange:(NSRange)range {
	range.location = MIN(range.location, self.text.length);
	range.length = MIN(range.length, self.text.length - range.location);
	UITextPosition *beginning = self.beginningOfDocument;
	UITextPosition *start = [self positionFromPosition:beginning offset:range.location];
	UITextPosition *end = [self positionFromPosition:start offset:range.length];
	UITextRange *textRange = [self textRangeFromPosition:start toPosition:end];

	self.selectedTextRange = textRange;
}

- (NSRange)selectedRange {
	UITextPosition *beginning = self.beginningOfDocument;

	UITextRange *selectedRange = self.selectedTextRange;
	if (!beginning || !selectedRange) {
		return NSMakeRange(self.text.length, 0);
	}
	UITextPosition *selectionStart = selectedRange.start;
	UITextPosition *selectionEnd = selectedRange.end;

	const NSInteger location = [self offsetFromPosition:beginning toPosition:selectionStart];
	const NSInteger length = [self offsetFromPosition:selectionStart toPosition:selectionEnd];

	NSUInteger safeLocation = MIN((NSUInteger)MAX(location, 0), self.text.length);
	return NSMakeRange(safeLocation, MIN((NSUInteger)MAX(length, 0), self.text.length - safeLocation));
}

- (void)dealloc {
	self.delegate = nil;
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

// MARK: Keyboard

- (BOOL)canBecomeFirstResponder {
	return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	OSAppleTV::get_singleton()->key(KEY_ENTER, true);
	OSAppleTV::get_singleton()->key(KEY_ENTER, false);

	[textField resignFirstResponder];
	return YES;
}

- (BOOL)becomeFirstResponderWithString:(NSString *)existingString multiline:(BOOL)flag cursorStart:(NSInteger)start cursorEnd:(NSInteger)end {
	self.text = existingString ?: @"";
	self.previousText = self.text;

	// Godot cursor offsets count Unicode code points; UIKit uses UTF-16 units.
	String text = String::utf8(self.text.UTF8String);
	int cursorStart = start < 0 ? text.length() : MIN(start, text.length());
	int cursorEnd = end < 0 ? cursorStart : MAX(cursorStart, MIN(end, text.length()));
	NSString *prefix = [NSString stringWithUTF8String:text.substr(0, cursorStart).utf8().get_data()];
	NSString *selection = [NSString stringWithUTF8String:text.substr(cursorStart, cursorEnd - cursorStart).utf8().get_data()];
	NSRange textRange = NSMakeRange(prefix.length, selection.length);

	self.selectedRange = textRange;
	self.previousSelectedRange = textRange;

	return [self becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
	BOOL resigned = [super resignFirstResponder];
	if (resigned) {
		self.text = nil;
		self.previousText = nil;
		self.previousSelectedRange = NSMakeRange(0, 0);
	}
	return resigned;
}

// MARK: OS Messages

- (void)deleteText:(NSInteger)charactersToDelete {
	for (int i = 0; i < charactersToDelete; i++) {
		OSAppleTV::get_singleton()->key(KEY_BACKSPACE, true);
		OSAppleTV::get_singleton()->key(KEY_BACKSPACE, false);
	}
}

- (void)enterText:(NSString *)substring {
	String characters;
	characters.parse_utf8([substring UTF8String]);

	for (int i = 0; i < characters.length(); i++) {
		int character = characters[i];

		switch (character) {
			case 10:
				character = KEY_ENTER;
				break;
			case 8198:
				character = KEY_SPACE;
				break;
			default:
				break;
		}

		OSAppleTV::get_singleton()->key(character, true);
		OSAppleTV::get_singleton()->key(character, false);
	}
}

// MARK: Observer

- (void)observeTextChange:(NSNotification *)notification {
	if (notification.object != self || !self.text || !OSAppleTV::get_singleton()) {
		return;
	}

	if (self.previousSelectedRange.length == 0) {
		// We are deleting all text before cursor if no range was selected.
		// This way any inserted or changed text will be updated.
		NSUInteger previousLocation = MIN(self.previousSelectedRange.location, self.previousText.length);
		NSString *substringToDelete = [self.previousText substringToIndex:previousLocation];
		[self deleteText:String::utf8(substringToDelete.UTF8String).length()];
	} else {
		// If text was previously selected
		// we are sending only one `backspace`.
		// It will remove all text from text input.
		[self deleteText:1];
	}

	NSString *substringToEnter;

	if (self.selectedRange.length == 0) {
		// If previous cursor had a selection
		// we have to calculate an inserted text.
		if (self.previousSelectedRange.length != 0) {
			NSInteger rangeEnd = self.selectedRange.location + self.selectedRange.length;
			NSInteger rangeStart = MIN(self.previousSelectedRange.location, self.selectedRange.location);
			NSInteger rangeLength = MAX(0, rangeEnd - rangeStart);

			NSRange calculatedRange;

			if (rangeLength >= 0) {
				calculatedRange = NSMakeRange(rangeStart, rangeLength);
			} else {
				calculatedRange = NSMakeRange(rangeStart, 0);
			}

			substringToEnter = [self.text substringWithRange:calculatedRange];
		} else {
			substringToEnter = [self.text substringToIndex:self.selectedRange.location];
		}
	} else {
		substringToEnter = [self.text substringWithRange:self.selectedRange];
	}

	[self enterText:substringToEnter];

	self.previousText = self.text;
	self.previousSelectedRange = self.selectedRange;
}

@end
