/**************************************************************************/
/*  godot_appletv.mm                                                      */
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

#include "core/ustring.h"
#include "core/vector.h"
#include "main/main.h"
#include "os_appletv.h"

#import <Foundation/Foundation.h>
#include <unistd.h>

static OSAppleTV *os = nullptr;

int appletv_main(int argc, char **argv, String data_dir, String cache_dir) {
	if (os) {
		return 0;
	}
	if (argc < 1 || !argv || !argv[0]) {
		return 255;
	}

	// Bundle paths and launch arguments need not fit the original fixed 512/64
	// buffers (for example long plugin-generated command lines).
	NSString *bundlePath = [NSBundle mainBundle].resourcePath;
	if (!bundlePath || chdir(bundlePath.fileSystemRepresentation) != 0) {
		return 255;
	}

	Vector<char *> arguments;
	for (int i = 0; i < argc; i++) {
		arguments.push_back(argv[i]);
	}

	NSDictionary *info = [NSBundle mainBundle].infoDictionary;
	NSString *projectPath = info[@"godot_path"];
	if ([projectPath isKindOfClass:[NSString class]]) {
		arguments.push_back((char *)"--path");
		arguments.push_back((char *)projectPath.UTF8String);
	}
	NSArray *commandLine = info[@"godot_cmdline"];
	if ([commandLine isKindOfClass:[NSArray class]]) {
		for (id argument in commandLine) {
			if ([argument isKindOfClass:[NSString class]]) {
				arguments.push_back((char *)[(NSString *)argument UTF8String]);
			}
		}
	}
	arguments.push_back(nullptr);

	os = new OSAppleTV(data_dir, cache_dir);
	Error err = Main::setup(arguments[0], arguments.size() - 2, arguments.ptrw() + 1, false);
	if (err != OK) {
		// --help/--version are a successful command-line exit, not a running app.
		if (err == ERR_HELP) {
			exit(0);
		}
		return 255;
	}
	return 0;
}

void appletv_finish() {
	if (!os) {
		return;
	}
	Main::cleanup();
	delete os;
	os = nullptr;
}
