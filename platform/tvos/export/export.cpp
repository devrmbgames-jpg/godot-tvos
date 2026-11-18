/**************************************************************************/
/*  export.cpp                                                            */
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

#include "export.h"
#include "core/io/marshalls.h"
#include "core/io/resource_saver.h"
#include "core/io/zip_io.h"
#include "core/os/file_access.h"
#include "core/os/os.h"
#include "core/project_settings.h"
#include "core/version.h"
#include "editor/editor_export.h"
#include "editor/editor_node.h"
#include "editor/editor_settings.h"
#include "main/splash.gen.h"
#include "platform/tvos/logo.gen.h"
#include "platform/tvos/plugin/godot_plugin_config.h"
#include "string.h"

#include <sys/stat.h>

class EditorExportPlatformTVOS : public EditorExportPlatform {
	GDCLASS(EditorExportPlatformTVOS, EditorExportPlatform);

	int version_code;

	Ref<ImageTexture> logo;

	// Plugins
	SafeFlag plugins_changed;
	Thread check_for_changes_thread;
	SafeFlag quit_request;
	Mutex plugins_lock;
	Vector<PluginConfigTVOS> plugins;

	typedef Error (*FileHandler)(String p_file, void *p_userdata);
	static Error _walk_dir_recursive(DirAccess *p_da, FileHandler p_handler, void *p_userdata);

	struct TVOSConfigData {
		String pkg_name;
		String binary_name;
		String plist_content;
		String linker_flags;
		String cpp_code;
		String modules_buildfile;
		String modules_fileref;
		String modules_buildphase;
		String modules_buildgrp;
		Vector<String> capabilities;
	};
	struct ExportArchitecture {
		String name;
		bool is_default;

		ExportArchitecture() :
				name(""),
				is_default(false) {
		}

		ExportArchitecture(String p_name, bool p_is_default) {
			name = p_name;
			is_default = p_is_default;
		}
	};

	struct TVOSExportAsset {
		String exported_path;
		bool is_framework; // framework is anything linked to the binary, otherwise it's a resource
		bool should_embed;
	};

	String _get_additional_plist_content();
	String _get_linker_flags();
	String _get_cpp_code();
	Error _fix_config_file(const Ref<EditorExportPreset> &p_preset, Vector<uint8_t> &pfile, const TVOSConfigData &p_config, bool p_debug, bool p_is_plist);

	void _add_assets_to_project(const Ref<EditorExportPreset> &p_preset, Vector<uint8_t> &p_project_data, const Vector<TVOSExportAsset> &p_additional_assets);
	Error _copy_asset(const String &p_out_dir, const String &p_asset, const String *p_custom_file_name, bool p_is_framework, bool p_should_embed, Vector<TVOSExportAsset> &r_exported_assets);
	Error _export_additional_assets(const String &p_out_dir, const Vector<String> &p_assets, bool p_is_framework, bool p_should_embed, Vector<TVOSExportAsset> &r_exported_assets);
	Error _export_additional_assets(const String &p_out_dir, const Vector<SharedObject> &p_libraries, Vector<TVOSExportAsset> &r_exported_assets);
	Error _export_tvos_plugins(const Ref<EditorExportPreset> &p_preset, TVOSConfigData &p_config_data, const String &dest_dir, Vector<TVOSExportAsset> &r_exported_assets, bool p_debug);

	bool is_package_name_valid(const String &p_package, String *r_error = NULL) const {
		String pname = p_package;

		if (pname.length() == 0) {
			if (r_error) {
				*r_error = TTR("Identifier is missing.");
			}
			return false;
		}

		for (int i = 0; i < pname.length(); i++) {
			CharType c = pname[i];
			if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.')) {
				if (r_error) {
					*r_error = vformat(TTR("The character '%s' is not allowed in Identifier."), String::chr(c));
				}
				return false;
			}
		}

		return true;
	}

	static void _check_for_changes_poll_thread(void *ud) {
		EditorExportPlatformTVOS *ea = (EditorExportPlatformTVOS *)ud;

		while (!ea->quit_request.is_set()) {
			// Nothing to do if we already know the plugins have changed.
			if (!ea->plugins_changed.is_set()) {
				ea->plugins_lock.lock();

				Vector<PluginConfigTVOS> loaded_plugins = get_plugins();

				if (ea->plugins.size() != loaded_plugins.size()) {
					ea->plugins_changed.set();
				} else {
					for (int i = 0; i < ea->plugins.size(); i++) {
						if (ea->plugins[i].name != loaded_plugins[i].name || ea->plugins[i].last_updated != loaded_plugins[i].last_updated) {
							ea->plugins_changed.set();
							break;
						}
					}
				}

				ea->plugins_lock.unlock();
			}

			uint64_t wait = 3000000;
			uint64_t time = OS::get_singleton()->get_ticks_usec();
			while (OS::get_singleton()->get_ticks_usec() - time < wait) {
				OS::get_singleton()->delay_usec(300000);

				if (ea->quit_request.is_set()) {
					break;
				}
			}
		}
	}

protected:
	virtual void get_preset_features(const Ref<EditorExportPreset> &p_preset, List<String> *r_features);
	virtual void get_export_options(List<ExportOption> *r_options);

public:
	virtual String get_name() const { return "tvOS"; }
	virtual String get_os_name() const { return "tvOS"; }
	virtual Ref<Texture> get_logo() const { return logo; }

	virtual bool should_update_export_options() {
		bool export_options_changed = plugins_changed.is_set();
		if (export_options_changed) {
			// don't clear unless we're reporting true, to avoid race
			plugins_changed.clear();
		}
		return export_options_changed;
	}

	virtual List<String> get_binary_extensions(const Ref<EditorExportPreset> &p_preset) const {
		List<String> list;
		// This exporter creates an Xcode project; Xcode builds/signs the IPA.
		list.push_back("xcodeproj");
		return list;
	}

	virtual Error export_project(const Ref<EditorExportPreset> &p_preset, bool p_debug, const String &p_path, int p_flags = 0);

	virtual bool has_valid_export_configuration(
			const Ref<EditorExportPreset> &p_preset,
			String &r_error,
			bool &r_missing_templates) const override;

	virtual bool has_valid_project_configuration(
			const Ref<EditorExportPreset> &p_preset,
			String &r_error) const override;

	virtual void get_platform_features(List<String> *r_features) {
		r_features->push_back("mobile");
		r_features->push_back("tvOS");
	}

	virtual void resolve_platform_feature_priorities(const Ref<EditorExportPreset> &p_preset, Set<String> &p_features) {
	}

	EditorExportPlatformTVOS();
	~EditorExportPlatformTVOS();

	/// List the gdip files in the directory specified by the p_path parameter.
	static Vector<String> list_plugin_config_files(const String &p_path, bool p_check_directories) {
		Vector<String> dir_files;
		DirAccessRef da = DirAccess::open(p_path);
		if (da) {
			da->list_dir_begin();
			while (true) {
				String file = da->get_next();
				if (file.empty()) {
					break;
				}

				if (file == "." || file == "..") {
					continue;
				}

				if (da->current_is_hidden()) {
					continue;
				}

				if (da->current_is_dir()) {
					if (p_check_directories) {
						Vector<String> directory_files = list_plugin_config_files(p_path.plus_file(file), false);
						for (int i = 0; i < directory_files.size(); ++i) {
							dir_files.push_back(file.plus_file(directory_files[i]));
						}
					}

					continue;
				}

				if (file.ends_with(PluginConfigTVOS::PLUGIN_CONFIG_EXT)) {
					dir_files.push_back(file);
				}
			}
			da->list_dir_end();
		}

		return dir_files;
	}

	static Vector<PluginConfigTVOS> get_plugins() {
		Vector<PluginConfigTVOS> loaded_plugins;

		String plugins_dir = ProjectSettings::get_singleton()->get_resource_path().plus_file("tvos/plugins");

		if (DirAccess::exists(plugins_dir)) {
			Vector<String> plugins_filenames = list_plugin_config_files(plugins_dir, true);

			if (!plugins_filenames.empty()) {
				Ref<ConfigFile> config_file = memnew(ConfigFile);
				for (int i = 0; i < plugins_filenames.size(); i++) {
					PluginConfigTVOS config = tvos_load_plugin_config(config_file, plugins_dir.plus_file(plugins_filenames[i]));
					if (config.valid_config) {
						loaded_plugins.push_back(config);
					} else {
						print_error("Invalid plugin config file " + plugins_filenames[i]);
					}
				}
			}
		}

		return loaded_plugins;
	}

	static Vector<PluginConfigTVOS> get_enabled_plugins(const Ref<EditorExportPreset> &p_presets) {
		Vector<PluginConfigTVOS> enabled_plugins;
		Vector<PluginConfigTVOS> all_plugins = get_plugins();
		for (int i = 0; i < all_plugins.size(); i++) {
			PluginConfigTVOS plugin = all_plugins[i];
			bool enabled = p_presets->get("plugins/" + plugin.name);
			if (enabled) {
				enabled_plugins.push_back(plugin);
			}
		}

		return enabled_plugins;
	}
};

void EditorExportPlatformTVOS::get_preset_features(const Ref<EditorExportPreset> &p_preset, List<String> *r_features) {
	String driver = ProjectSettings::get_singleton()->get("rendering/quality/driver/driver_name");
	r_features->push_back("pvrtc");
	if (driver == "GLES3") {
		r_features->push_back("etc2");
	}

	r_features->push_back("arm64");
}

void EditorExportPlatformTVOS::get_export_options(List<ExportOption> *r_options) {
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "custom_template/debug", PROPERTY_HINT_GLOBAL_FILE, "*.zip"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "custom_template/release", PROPERTY_HINT_GLOBAL_FILE, "*.zip"), ""));

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/app_store_team_id"), ""));

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/name", PROPERTY_HINT_PLACEHOLDER_TEXT, "Game Name"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/info"), "Made with Godot Engine"));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/bundle_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT, "com.example.game"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/short_version"), "1.0"));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/build_version"), "1"));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/copyright"), ""));

	Vector<PluginConfigTVOS> found_plugins = get_plugins();
	for (int i = 0; i < found_plugins.size(); i++) {
		r_options->push_back(ExportOption(PropertyInfo(Variant::BOOL, "plugins/" + found_plugins[i].name), false));
	}

	plugins_lock.lock();
	plugins_changed.clear();
	plugins = found_plugins;
	plugins_lock.unlock();
}

Error EditorExportPlatformTVOS::_fix_config_file(const Ref<EditorExportPreset> &p_preset, Vector<uint8_t> &pfile, const TVOSConfigData &p_config, bool p_debug, bool p_is_plist) {
	String text = String::utf8((const char *)pfile.ptr(), pfile.size());
	bool is_xml = p_is_plist || text.strip_edges().begins_with("<?xml");
	Map<String, String> values;
	values["$binary"] = p_config.binary_name;
	values["$name"] = p_config.pkg_name;
	values["$info"] = p_preset->get("application/info");
	values["$bundle_identifier"] = p_preset->get("application/bundle_identifier");
	values["$short_version"] = p_preset->get("application/short_version");
	values["$build_version"] = p_preset->get("application/build_version");
	values["$copyright"] = p_preset->get("application/copyright");
	values["$team_id"] = p_preset->get("application/app_store_team_id");
	values["$default_build_config"] = p_debug ? "Debug" : "Release";
	for (Map<String, String>::Element *E = values.front(); E; E = E->next()) {
		String value = is_xml ? E->value().xml_escape(true) : E->value().c_escape();
		text = text.replace(E->key(), value);
	}

	// These placeholders contain complete XML, C++ or Xcode project fragments.
	text = text.replace("$modules_buildfile", p_config.modules_buildfile);
	text = text.replace("$modules_fileref", p_config.modules_fileref);
	text = text.replace("$modules_buildphase", p_config.modules_buildphase);
	text = text.replace("$modules_buildgrp", p_config.modules_buildgrp);
	text = text.replace("$additional_plist_content", p_config.plist_content);
	text = text.replace("$linker_flags", p_config.linker_flags);
	text = text.replace("$cpp_code", p_config.cpp_code);
	String capabilities;
	for (int i = 0; i < p_config.capabilities.size(); i++) {
		capabilities += "<string>" + p_config.capabilities[i].xml_escape() + "</string>\n";
	}
	text = text.replace("$required_device_capabilities", capabilities);

	if (p_is_plist) {
		// Upgrade existing custom templates as well as the bundled Xcode project.
		// The application delegate supplies SceneDelegate programmatically.
		String additions;
		if (text.find("<key>UIApplicationSceneManifest</key>") == -1) {
			additions += "<key>UIApplicationSceneManifest</key><dict>\n"
						 "<key>UIApplicationSupportsMultipleScenes</key><false/>\n"
						 "<key>UISceneConfigurations</key><dict>\n"
						 "<key>UIWindowSceneSessionRoleApplication</key><array><dict>\n"
						 "<key>UISceneConfigurationName</key><string>Default Configuration</string>\n"
						 "<key>UISceneClassName</key><string>UIWindowScene</string>\n"
						 "<key>UISceneDelegateClassName</key><string>SceneDelegate</string>\n"
						 "</dict></array></dict></dict>\n";
		}
		int profiles = text.find("<key>GCSupportedGameControllers</key>");
		if (profiles == -1) {
			additions += "<key>GCSupportedGameControllers</key><array>\n"
						 "<dict><key>ProfileName</key><string>MicroGamepad</string></dict>\n"
						 "<dict><key>ProfileName</key><string>ExtendedGamepad</string></dict>\n"
						 "<dict><key>ProfileName</key><string>DirectionalGamepad</string></dict>\n"
						 "</array>\n";
		} else {
			int end = text.find("</array>", profiles);
			ERR_FAIL_COND_V(end == -1, ERR_FILE_CORRUPT);
			if (text.substr(profiles, end - profiles).find("DirectionalGamepad") == -1) {
				text = text.insert(end, "<dict><key>ProfileName</key><string>DirectionalGamepad</string></dict>\n");
			}
		}
		if (text.find("<key>GCSupportsMultipleMicroGamepads</key>") == -1) {
			additions += "<key>GCSupportsMultipleMicroGamepads</key><true/>\n";
		}
		int end = text.rfind("</dict>");
		ERR_FAIL_COND_V(end == -1, ERR_FILE_CORRUPT);
		text = text.insert(end, additions);
	}

	CharString utf8 = text.utf8();
	pfile.resize(utf8.length());
	if (utf8.length()) {
		memcpy(pfile.ptrw(), utf8.get_data(), utf8.length());
	}
	return OK;
}

String EditorExportPlatformTVOS::_get_additional_plist_content() {
	Vector<Ref<EditorExportPlugin>> export_plugins = EditorExport::get_singleton()->get_export_plugins();
	String result;
	for (int i = 0; i < export_plugins.size(); ++i) {
		result += export_plugins[i]->get_tvos_plist_content();
	}
	return result;
}

String EditorExportPlatformTVOS::_get_linker_flags() {
	Vector<Ref<EditorExportPlugin>> export_plugins = EditorExport::get_singleton()->get_export_plugins();
	String result;
	for (int i = 0; i < export_plugins.size(); ++i) {
		String flags = export_plugins[i]->get_tvos_linker_flags();
		if (flags.length() == 0)
			continue;
		if (result.length() > 0) {
			result += ' ';
		}
		result += flags;
	}
	// the flags will be enclosed in quotes, so need to escape them
	return result.replace("\"", "\\\"");
}

String EditorExportPlatformTVOS::_get_cpp_code() {
	Vector<Ref<EditorExportPlugin>> export_plugins = EditorExport::get_singleton()->get_export_plugins();
	String result;
	for (int i = 0; i < export_plugins.size(); ++i) {
		result += export_plugins[i]->get_tvos_cpp_code();
	}
	return result;
}

Error EditorExportPlatformTVOS::_walk_dir_recursive(DirAccess *p_da, FileHandler p_handler, void *p_userdata) {
	Vector<String> dirs;
	String path;
	String current_dir = p_da->get_current_dir();
	p_da->list_dir_begin();
	while ((path = p_da->get_next()).length() != 0) {
		if (p_da->current_is_dir()) {
			if (path != "." && path != "..") {
				dirs.push_back(path);
			}
		} else {
			Error err = p_handler(current_dir.plus_file(path), p_userdata);
			if (err) {
				p_da->list_dir_end();
				return err;
			}
		}
	}
	p_da->list_dir_end();

	for (int i = 0; i < dirs.size(); ++i) {
		String dir = dirs[i];
		p_da->change_dir(dir);
		Error err = _walk_dir_recursive(p_da, p_handler, p_userdata);
		p_da->change_dir("..");
		if (err) {
			return err;
		}
	}

	return OK;
}

struct TVOSPbxId {
private:
	static char _hex_char(uint8_t four_bits) {
		if (four_bits < 10) {
			return ('0' + four_bits);
		}
		return 'A' + (four_bits - 10);
	}

	static String _hex_pad(uint32_t num) {
		Vector<char> ret;
		ret.resize(sizeof(num) * 2);
		for (uint64_t i = 0; i < sizeof(num) * 2; ++i) {
			uint8_t four_bits = (num >> (sizeof(num) * 8 - (i + 1) * 4)) & 0xF;
			ret.write[i] = _hex_char(four_bits);
		}
		return String::utf8(ret.ptr(), ret.size());
	}

public:
	uint32_t high_bits;
	uint32_t mid_bits;
	uint32_t low_bits;

	String str() const {
		return _hex_pad(high_bits) + _hex_pad(mid_bits) + _hex_pad(low_bits);
	}

	TVOSPbxId &operator++() {
		low_bits++;
		if (!low_bits) {
			mid_bits++;
			if (!mid_bits) {
				high_bits++;
			}
		}

		return *this;
	}
};

struct TVOSExportLibsData {
	Vector<String> lib_paths;
	String dest_dir;
};

void EditorExportPlatformTVOS::_add_assets_to_project(const Ref<EditorExportPreset> &p_preset, Vector<uint8_t> &p_project_data, const Vector<TVOSExportAsset> &p_additional_assets) {
	// that is just a random number, we just need Godot IDs not to clash with
	// existing IDs in the project.
	TVOSPbxId current_id = { 0x58938401, 0, 0 };
	String pbx_files;
	String pbx_frameworks_build;
	String pbx_frameworks_refs;
	String pbx_resources_build;
	String pbx_resources_refs;
	String pbx_embeded_frameworks;

	const String file_info_format = String("$build_id = {isa = PBXBuildFile; fileRef = $ref_id; };\n") +
			"$ref_id = {isa = PBXFileReference; lastKnownFileType = $file_type; name = \"$name\"; path = \"$file_path\"; sourceTree = \"<group>\"; };\n";

	for (int i = 0; i < p_additional_assets.size(); ++i) {
		String additional_asset_info_format = file_info_format;

		String build_id = (++current_id).str();
		String ref_id = (++current_id).str();
		String framework_id = "";

		const TVOSExportAsset &asset = p_additional_assets[i];

		String type;
		if (asset.exported_path.ends_with(".framework")) {
			if (asset.should_embed) {
				additional_asset_info_format += "$framework_id = {isa = PBXBuildFile; fileRef = $ref_id; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };\n";
				framework_id = (++current_id).str();
				pbx_embeded_frameworks += framework_id + ",\n";
			}

			type = "wrapper.framework";
		} else if (asset.exported_path.ends_with(".xcframework")) {
			if (asset.should_embed) {
				additional_asset_info_format += "$framework_id = {isa = PBXBuildFile; fileRef = $ref_id; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };\n";
				framework_id = (++current_id).str();
				pbx_embeded_frameworks += framework_id + ",\n";
			}

			type = "wrapper.xcframework";
		} else if (asset.exported_path.ends_with(".dylib")) {
			type = "compiled.mach-o.dylib";
		} else if (asset.exported_path.ends_with(".a")) {
			type = "archive.ar";
		} else {
			type = "file";
		}

		String &pbx_build = asset.is_framework ? pbx_frameworks_build : pbx_resources_build;
		String &pbx_refs = asset.is_framework ? pbx_frameworks_refs : pbx_resources_refs;

		if (pbx_build.length() > 0) {
			pbx_build += ",\n";
			pbx_refs += ",\n";
		}
		pbx_build += build_id;
		pbx_refs += ref_id;

		Dictionary format_dict;
		format_dict["build_id"] = build_id;
		format_dict["ref_id"] = ref_id;
		format_dict["name"] = asset.exported_path.get_file().c_escape();
		format_dict["file_path"] = asset.exported_path.c_escape();
		format_dict["file_type"] = type;
		if (framework_id.length() > 0) {
			format_dict["framework_id"] = framework_id;
		}
		pbx_files += additional_asset_info_format.format(format_dict, "$_");
	}

	// Note, frameworks like gamekit are always included in our project.pbxprof file
	// even if turned off in capabilities.

	String str = String::utf8((const char *)p_project_data.ptr(), p_project_data.size());
	str = str.replace("$additional_pbx_files", pbx_files);
	str = str.replace("$additional_pbx_frameworks_build", pbx_frameworks_build);
	str = str.replace("$additional_pbx_frameworks_refs", pbx_frameworks_refs);
	str = str.replace("$additional_pbx_resources_build", pbx_resources_build);
	str = str.replace("$additional_pbx_resources_refs", pbx_resources_refs);
	str = str.replace("$pbx_embeded_frameworks", pbx_embeded_frameworks);

	CharString cs = str.utf8();
	p_project_data.resize(cs.size() - 1);
	for (int i = 0; i < cs.size() - 1; i++) {
		p_project_data.write[i] = cs[i];
	}
}

Error EditorExportPlatformTVOS::_copy_asset(const String &p_out_dir, const String &p_asset, const String *p_custom_file_name, bool p_is_framework, bool p_should_embed, Vector<TVOSExportAsset> &r_exported_assets) {
	DirAccess *filesystem_da = DirAccess::create(DirAccess::ACCESS_FILESYSTEM);
	ERR_FAIL_COND_V_MSG(!filesystem_da, ERR_CANT_CREATE, "Cannot create DirAccess for path '" + p_out_dir + "'.");

	String binary_name = p_out_dir.get_file();

	DirAccess *da = DirAccess::create_for_path(p_asset);
	if (!da) {
		memdelete(filesystem_da);
		ERR_FAIL_V_MSG(ERR_CANT_CREATE, "Can't create directory: " + p_asset + ".");
	}
	bool file_exists = da->file_exists(p_asset);
	bool dir_exists = da->dir_exists(p_asset);
	if (!file_exists && !dir_exists) {
		memdelete(da);
		memdelete(filesystem_da);
		return ERR_FILE_NOT_FOUND;
	}

	String base_dir = p_asset.get_base_dir().replace("res://", "");
	String destination_dir;
	String destination;
	String asset_path;

	bool create_framework = false;

	if (p_is_framework && p_asset.ends_with(".dylib")) {
		// For tvOS we need to turn .dylib into .framework
		// to be able to send application to AppStore
		asset_path = String("dylibs").plus_file(base_dir);

		String file_name;

		if (!p_custom_file_name) {
			file_name = p_asset.get_basename().get_file();
		} else {
			file_name = *p_custom_file_name;
		}

		String framework_name = file_name + ".framework";

		asset_path = asset_path.plus_file(framework_name);
		destination_dir = p_out_dir.plus_file(asset_path);
		destination = destination_dir.plus_file(file_name);
		create_framework = true;
	} else if (p_is_framework && (p_asset.ends_with(".framework") || p_asset.ends_with(".xcframework"))) {
		asset_path = String("dylibs").plus_file(base_dir);

		String file_name;

		if (!p_custom_file_name) {
			file_name = p_asset.get_file();
		} else {
			file_name = *p_custom_file_name;
		}

		asset_path = asset_path.plus_file(file_name);
		destination_dir = p_out_dir.plus_file(asset_path);
		destination = destination_dir;
	} else {
		asset_path = base_dir;

		String file_name;

		if (!p_custom_file_name) {
			file_name = p_asset.get_file();
		} else {
			file_name = *p_custom_file_name;
		}

		destination_dir = p_out_dir.plus_file(asset_path);
		asset_path = asset_path.plus_file(file_name);
		destination = p_out_dir.plus_file(asset_path);
	}

	if (!filesystem_da->dir_exists(destination_dir)) {
		Error make_dir_err = filesystem_da->make_dir_recursive(destination_dir);
		if (make_dir_err) {
			memdelete(da);
			memdelete(filesystem_da);
			return make_dir_err;
		}
	}

	Error err = dir_exists ? da->copy_dir(p_asset, destination) : da->copy(p_asset, destination);
	memdelete(da);
	if (err) {
		memdelete(filesystem_da);
		return err;
	}
	TVOSExportAsset exported_asset = { binary_name.plus_file(asset_path), p_is_framework, p_should_embed };
	r_exported_assets.push_back(exported_asset);

	if (create_framework) {
		String file_name;

		if (!p_custom_file_name) {
			file_name = p_asset.get_basename().get_file();
		} else {
			file_name = *p_custom_file_name;
		}

		String framework_name = file_name + ".framework";

		// Performing `install_name_tool -id @rpath/{name}.framework/{name} ./{name}` on dylib
		{
			List<String> install_name_args;
			install_name_args.push_back("-id");
			install_name_args.push_back(String("@rpath").plus_file(framework_name).plus_file(file_name));
			install_name_args.push_back(destination);

			OS::get_singleton()->execute("install_name_tool", install_name_args, true);
		}

		// Creating Info.plist
		{
			String info_plist_format = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
									   "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
									   "<plist version=\"1.0\">\n"
									   "<dict>\n"
									   "<key>CFBundleShortVersionString</key>\n"
									   "<string>1.0</string>\n"
									   "<key>CFBundleIdentifier</key>\n"
									   "<string>com.gdnative.framework.$name</string>\n"
									   "<key>CFBundleName</key>\n"
									   "<string>$name</string>\n"
									   "<key>CFBundleExecutable</key>\n"
									   "<string>$name</string>\n"
									   "<key>DTPlatformName</key>\n"
									   "<string>appletvos</string>\n"
									   "<key>CFBundleInfoDictionaryVersion</key>\n"
									   "<string>6.0</string>\n"
									   "<key>CFBundleVersion</key>\n"
									   "<string>1</string>\n"
									   "<key>CFBundlePackageType</key>\n"
									   "<string>FMWK</string>\n"
									   "<key>MinimumOSVersion</key>\n"
									   "<string>15.0</string>\n"
									   "</dict>\n"
									   "</plist>";

			String info_plist = info_plist_format.replace("$name", file_name);

			FileAccess *f = FileAccess::open(destination_dir.plus_file("Info.plist"), FileAccess::WRITE);
			if (f) {
				f->store_string(info_plist);
				f->close();
				memdelete(f);
			}
		}
	}

	memdelete(filesystem_da);

	return OK;
}

Error EditorExportPlatformTVOS::_export_additional_assets(const String &p_out_dir, const Vector<String> &p_assets, bool p_is_framework, bool p_should_embed, Vector<TVOSExportAsset> &r_exported_assets) {
	for (int f_idx = 0; f_idx < p_assets.size(); ++f_idx) {
		String asset = p_assets[f_idx];
		if (!asset.begins_with("res://")) {
			// either SDK-builtin or already a part of the export template
			TVOSExportAsset exported_asset = { asset, p_is_framework, p_should_embed };
			r_exported_assets.push_back(exported_asset);
		} else {
			Error err = _copy_asset(p_out_dir, asset, nullptr, p_is_framework, p_should_embed, r_exported_assets);
			ERR_FAIL_COND_V(err, err);
		}
	}

	return OK;
}

Error EditorExportPlatformTVOS::_export_additional_assets(const String &p_out_dir, const Vector<SharedObject> &p_libraries, Vector<TVOSExportAsset> &r_exported_assets) {
	Vector<Ref<EditorExportPlugin>> export_plugins = EditorExport::get_singleton()->get_export_plugins();
	for (int i = 0; i < export_plugins.size(); i++) {
		Vector<String> linked_frameworks = export_plugins[i]->get_tvos_frameworks();
		Error err = _export_additional_assets(p_out_dir, linked_frameworks, true, false, r_exported_assets);
		ERR_FAIL_COND_V(err, err);

		Vector<String> embedded_frameworks = export_plugins[i]->get_tvos_embedded_frameworks();
		err = _export_additional_assets(p_out_dir, embedded_frameworks, true, true, r_exported_assets);
		ERR_FAIL_COND_V(err, err);

		Vector<String> project_static_libs = export_plugins[i]->get_tvos_project_static_libs();
		for (int j = 0; j < project_static_libs.size(); j++)
			project_static_libs.write[j] = project_static_libs[j].get_file(); // Only the file name as it's copied to the project
		err = _export_additional_assets(p_out_dir, project_static_libs, true, true, r_exported_assets);
		ERR_FAIL_COND_V(err, err);

		Vector<String> tvos_bundle_files = export_plugins[i]->get_tvos_bundle_files();
		err = _export_additional_assets(p_out_dir, tvos_bundle_files, false, false, r_exported_assets);
		ERR_FAIL_COND_V(err, err);
	}

	Vector<String> library_paths;
	for (int i = 0; i < p_libraries.size(); ++i) {
		library_paths.push_back(p_libraries[i].path);
	}
	Error err = _export_additional_assets(p_out_dir, library_paths, true, true, r_exported_assets);
	ERR_FAIL_COND_V(err, err);

	return OK;
}

Error EditorExportPlatformTVOS::_export_tvos_plugins(const Ref<EditorExportPreset> &p_preset, TVOSConfigData &p_config_data, const String &dest_dir, Vector<TVOSExportAsset> &r_exported_assets, bool p_debug) {
	String plugin_definition_cpp_code;
	String plugin_initialization_cpp_code;
	String plugin_deinitialization_cpp_code;

	Vector<String> plugin_linked_dependencies;
	Vector<String> plugin_embedded_dependencies;
	Vector<String> plugin_files;

	Vector<PluginConfigTVOS> enabled_plugins = get_enabled_plugins(p_preset);

	Vector<String> added_linked_dependenciy_names;
	Vector<String> added_embedded_dependenciy_names;
	HashMap<String, String> plist_values;

	Error err;

	for (int i = 0; i < enabled_plugins.size(); i++) {
		PluginConfigTVOS plugin = enabled_plugins[i];

		// Export plugin binary.
		String plugin_main_binary = tvos_get_plugin_main_binary(plugin, p_debug);
		String plugin_binary_result_file = plugin.binary.get_file();
		// We shouldn't embed .xcframework that contains static libraries.
		// Static libraries are not embedded anyway.
		err = _copy_asset(dest_dir, plugin_main_binary, &plugin_binary_result_file, true, false, r_exported_assets);

		ERR_FAIL_COND_V(err, err);

		// Adding dependencies.
		// Use separate container for names to check for duplicates.
		for (int j = 0; j < plugin.linked_dependencies.size(); j++) {
			String dependency = plugin.linked_dependencies[j];
			String name = dependency.get_file();

			if (added_linked_dependenciy_names.find(name) != -1) {
				continue;
			}

			added_linked_dependenciy_names.push_back(name);
			plugin_linked_dependencies.push_back(dependency);
		}

		for (int j = 0; j < plugin.system_dependencies.size(); j++) {
			String dependency = plugin.system_dependencies[j];
			String name = dependency.get_file();

			if (added_linked_dependenciy_names.find(name) != -1) {
				continue;
			}

			added_linked_dependenciy_names.push_back(name);
			plugin_linked_dependencies.push_back(dependency);
		}

		for (int j = 0; j < plugin.embedded_dependencies.size(); j++) {
			String dependency = plugin.embedded_dependencies[j];
			String name = dependency.get_file();

			if (added_embedded_dependenciy_names.find(name) != -1) {
				continue;
			}

			added_embedded_dependenciy_names.push_back(name);
			plugin_embedded_dependencies.push_back(dependency);
		}

		plugin_files.append_array(plugin.files_to_copy);

		// Capabilities
		// Also checking for duplicates.
		for (int j = 0; j < plugin.capabilities.size(); j++) {
			String capability = plugin.capabilities[j];

			if (p_config_data.capabilities.find(capability) != -1) {
				continue;
			}

			p_config_data.capabilities.push_back(capability);
		}

		// Plist
		// Using hash map container to remove duplicates
		const String *K = nullptr;

		while ((K = plugin.plist.next(K))) {
			String key = *K;
			String value = plugin.plist[key];

			if (key.empty() || value.empty()) {
				continue;
			}

			plist_values[key] = value;
		}

		// CPP Code
		String definition_comment = "// Plugin: " + plugin.name + "\n";
		String initialization_method = plugin.initialization_method + "();\n";
		String deinitialization_method = plugin.deinitialization_method + "();\n";

		plugin_definition_cpp_code += definition_comment +
				"extern void " + initialization_method +
				"extern void " + deinitialization_method + "\n";

		plugin_initialization_cpp_code += "\t" + initialization_method;
		plugin_deinitialization_cpp_code += "\t" + deinitialization_method;
	}

	// Updating `Info.plist`
	{
		const String *K = nullptr;
		while ((K = plist_values.next(K))) {
			String key = *K;
			String value = plist_values[key];

			if (key.empty() || value.empty()) {
				continue;
			}

			p_config_data.plist_content += "<key>" + key.xml_escape() + "</key><string>" + value.xml_escape() + "</string>\n";
		}
	}

	// Export files
	{
		// Export linked plugin dependency
		err = _export_additional_assets(dest_dir, plugin_linked_dependencies, true, false, r_exported_assets);
		ERR_FAIL_COND_V(err, err);

		// Export embedded plugin dependency
		err = _export_additional_assets(dest_dir, plugin_embedded_dependencies, true, true, r_exported_assets);
		ERR_FAIL_COND_V(err, err);

		// Export plugin files
		err = _export_additional_assets(dest_dir, plugin_files, false, false, r_exported_assets);
		ERR_FAIL_COND_V(err, err);
	}

	// Update CPP
	{
		Dictionary plugin_format;
		plugin_format["definition"] = plugin_definition_cpp_code;
		plugin_format["initialization"] = plugin_initialization_cpp_code;
		plugin_format["deinitialization"] = plugin_deinitialization_cpp_code;

		String plugin_cpp_code = "\n// Godot Plugins\n"
								 "void godot_tvos_plugins_initialize();\n"
								 "void godot_tvos_plugins_deinitialize();\n"
								 "// Exported Plugins\n\n"
								 "$definition"
								 "// Use Plugins\n"
								 "void godot_tvos_plugins_initialize() {\n"
								 "$initialization"
								 "}\n\n"
								 "void godot_tvos_plugins_deinitialize() {\n"
								 "$deinitialization"
								 "}\n";

		p_config_data.cpp_code += plugin_cpp_code.format(plugin_format, "$_");
	}
	return OK;
}

Error EditorExportPlatformTVOS::export_project(const Ref<EditorExportPreset> &p_preset, bool p_debug, const String &p_path, int p_flags) {
	ExportNotifier notifier(*this, p_preset, p_debug, p_path, p_flags);

	String src_pkg_name;
	String dest_dir = p_path.get_base_dir() + "/";
	String binary_name = p_path.get_file().get_basename();
	ERR_FAIL_COND_V(binary_name.empty() || binary_name == "." || binary_name == "..", ERR_INVALID_PARAMETER);

	EditorProgress ep("export", "Exporting for tvOS", 5, true);

	String team_id = p_preset->get("application/app_store_team_id");

	if (p_debug)
		src_pkg_name = p_preset->get("custom_template/debug");
	else
		src_pkg_name = p_preset->get("custom_template/release");

	if (src_pkg_name == "") {
		String err;
		src_pkg_name = find_export_template("tvos.zip", &err);
		if (src_pkg_name == "") {
			EditorNode::add_io_error(err);
			return ERR_FILE_NOT_FOUND;
		}
	}

	if (!DirAccess::exists(dest_dir)) {
		return ERR_FILE_BAD_PATH;
	}

	// A tvOS export replaces its generated app/project directories. Never let
	// those directories overlap project sources or the template archive itself.
	String project_path = ProjectSettings::get_singleton()->get_resource_path().simplify_path();
	String export_path = ProjectSettings::get_singleton()->globalize_path(dest_dir).simplify_path();
	if (export_path == project_path || export_path.begins_with(project_path + "/")) {
		add_message(EXPORT_MESSAGE_ERROR, TTR("Export Location"), TTR("Export the tvOS Xcode project outside the Godot project directory."));
		return ERR_FILE_BAD_PATH;
	}
	String archive_path = ProjectSettings::get_singleton()->globalize_path(src_pkg_name).simplify_path();
	for (int i = 0; i < 3; i++) {
		String suffix = i == 0 ? "" : (i == 1 ? ".xcodeproj" : ".xcframework");
		String target = export_path.plus_file(binary_name + suffix);
		if (project_path == target || project_path.begins_with(target + "/") || archive_path.begins_with(target + "/")) {
			return ERR_FILE_BAD_PATH;
		}
	}

	String library_prefix = "libgodot.tvos." + String(p_debug ? "debug" : "release");
	String library_to_use = library_prefix + ".xcframework";
	String legacy_library = library_prefix + ".fat.a";
	const String project_file = "godot_tvos.xcodeproj/project.pbxproj";

	// Validate required members before replacing an existing exported project.
	FileAccess *preflight_file = nullptr;
	zlib_filefunc_def preflight_io = zipio_create_io_from_file(&preflight_file);
	unzFile preflight_zip = unzOpen2(src_pkg_name.utf8().get_data(), &preflight_io);
	if (!preflight_zip) {
		return ERR_CANT_OPEN;
	}
	bool template_has_project = false;
	bool template_has_plist = false;
	bool template_has_library = false;
	int preflight_result = unzGoToFirstFile(preflight_zip);
	while (preflight_result == UNZ_OK) {
		unz_file_info info;
		char filename[16384];
		if (unzGetCurrentFileInfo(preflight_zip, &info, filename, sizeof(filename), nullptr, 0, nullptr, 0) != UNZ_OK || info.size_filename >= sizeof(filename)) {
			unzClose(preflight_zip);
			return ERR_FILE_CORRUPT;
		}
		String member = String::utf8(filename).replace("\\", "/");
		if (member.begins_with("tvos/")) {
			member = member.substr(5);
		}
		if (member.is_abs_path() || member == ".." || member.begins_with("../") || member.find("/../") != -1 || member.ends_with("/..")) {
			unzClose(preflight_zip);
			return ERR_FILE_BAD_PATH;
		}
		if (info.uncompressed_size > 0) {
			template_has_project = template_has_project || member == project_file;
			template_has_plist = template_has_plist || member == "godot_tvos/Info.plist";
			template_has_library = template_has_library || member == legacy_library || (member.begins_with(library_to_use + "/") && member.ends_with(".a"));
		}
		preflight_result = unzGoToNextFile(preflight_zip);
	}
	unzClose(preflight_zip);
	if (preflight_result != UNZ_END_OF_LIST_OF_FILE || !template_has_project || !template_has_plist || !template_has_library) {
		add_message(EXPORT_MESSAGE_ERROR, TTR("Prepare Templates"), TTR("The tvOS template is missing its Xcode project, Info.plist, or the selected debug/release library."));
		return ERR_FILE_CORRUPT;
	}

	DirAccess *da = DirAccess::create(DirAccess::ACCESS_FILESYSTEM);
	if (da) {
		String current_dir = da->get_current_dir();

		// remove leftovers from last export so they don't interfere
		// in case some files are no longer needed
		if (da->change_dir(dest_dir + binary_name + ".xcodeproj") == OK) {
			da->erase_contents_recursive();
		}
		if (da->change_dir(dest_dir + binary_name) == OK) {
			da->erase_contents_recursive();
		}
		if (da->change_dir(dest_dir + binary_name + ".xcframework") == OK) {
			da->erase_contents_recursive();
		}

		da->change_dir(current_dir);

		if (!da->dir_exists(dest_dir + binary_name)) {
			Error err = da->make_dir(dest_dir + binary_name);
			if (err) {
				memdelete(da);
				return err;
			}
		}
		memdelete(da);
	}

	if (ep.step("Making .pck", 0)) {
		return ERR_SKIP;
	}
	String pack_path = dest_dir + binary_name + ".pck";
	Vector<SharedObject> libraries;
	Error err = save_pack(p_preset, pack_path, &libraries);
	if (err)
		return err;

	if (ep.step("Extracting and configuring Xcode project", 1)) {
		return ERR_SKIP;
	}

	print_line("Static library: " + library_to_use);
	String pkg_name;
	if (p_preset->get("application/name") != "")
		pkg_name = p_preset->get("application/name"); // app_name
	else if (String(ProjectSettings::get_singleton()->get("application/config/name")) != "")
		pkg_name = String(ProjectSettings::get_singleton()->get("application/config/name"));
	else
		pkg_name = "Unnamed";

	bool found_library = false;

	Set<String> files_to_parse;
	files_to_parse.insert("godot_tvos/Info.plist");
	files_to_parse.insert(project_file);
	files_to_parse.insert("godot_tvos/dummy.cpp");
	files_to_parse.insert("godot_tvos.xcodeproj/project.xcworkspace/contents.xcworkspacedata");
	files_to_parse.insert("godot_tvos.xcodeproj/xcshareddata/xcschemes/godot_tvos.xcscheme");
	files_to_parse.insert("godot_tvos/Launch Screen.storyboard");

	TVOSConfigData config_data = {
		pkg_name,
		binary_name,
		_get_additional_plist_content(),
		_get_linker_flags(),
		_get_cpp_code(),
		"",
		"",
		"",
		"",
		Vector<String>()
	};

	Vector<TVOSExportAsset> assets;

	DirAccess *tmp_app_path = DirAccess::create_for_path(dest_dir);
	ERR_FAIL_COND_V(!tmp_app_path, ERR_CANT_CREATE);

	print_line("Unzipping...");
	FileAccess *src_f = NULL;
	zlib_filefunc_def io = zipio_create_io_from_file(&src_f);
	unzFile src_pkg_zip = unzOpen2(src_pkg_name.utf8().get_data(), &io);
	if (!src_pkg_zip) {
		EditorNode::add_io_error("Could not open export template (not a zip file?):\n" + src_pkg_name);
		memdelete(tmp_app_path);
		return ERR_CANT_OPEN;
	}

	err = _export_tvos_plugins(p_preset, config_data, dest_dir + binary_name, assets, p_debug);
	if (err != OK) {
		unzClose(src_pkg_zip);
		memdelete(tmp_app_path);
		return err;
	}

	//export rest of the files
	int ret = unzGoToFirstFile(src_pkg_zip);
	Vector<uint8_t> project_file_data;
	while (ret == UNZ_OK) {
		//get filename
		unz_file_info info;
		char fname[16384];
		ret = unzGetCurrentFileInfo(src_pkg_zip, &info, fname, 16384, NULL, 0, NULL, 0);
		if (ret != UNZ_OK || info.size_filename >= sizeof(fname)) {
			unzClose(src_pkg_zip);
			memdelete(tmp_app_path);
			return ERR_FILE_CORRUPT;
		}

		String file = String::utf8(fname).replace("\\", "/");
		if (file.begins_with("tvos/")) {
			file = file.substr(5);
		}
		// Template members must stay inside the selected export directory.
		if (file.is_abs_path() || file == ".." || file.begins_with("../") || file.find("/../") != -1 || file.ends_with("/..")) {
			unzClose(src_pkg_zip);
			memdelete(tmp_app_path);
			return ERR_FILE_BAD_PATH;
		}

		print_line("READ: " + file);
		Vector<uint8_t> data;
		data.resize(info.uncompressed_size);

		//read
		if (unzOpenCurrentFile(src_pkg_zip) != UNZ_OK) {
			unzClose(src_pkg_zip);
			memdelete(tmp_app_path);
			return ERR_FILE_CORRUPT;
		}
		int bytes_read = unzReadCurrentFile(src_pkg_zip, data.ptrw(), data.size());
		int close_result = unzCloseCurrentFile(src_pkg_zip);
		if (bytes_read != data.size() || close_result != UNZ_OK) {
			unzClose(src_pkg_zip);
			memdelete(tmp_app_path);
			return ERR_FILE_CORRUPT;
		}

		//write

		if (files_to_parse.has(file)) {
			err = _fix_config_file(p_preset, data, config_data, p_debug, file == "godot_tvos/Info.plist");
			if (err != OK) {
				unzClose(src_pkg_zip);
				memdelete(tmp_app_path);
				return err;
			}
		} else if (file.begins_with("libgodot.tvos")) {
			if (file == legacy_library) {
				// Retain compatibility with the original device-only templates.
				found_library = true;
				file = "godot_tvos.a";
			} else if (file.begins_with(library_to_use + "/") && !file.ends_with("/empty")) {
				found_library = found_library || file.ends_with(".a");
				file = file.replace_first(library_to_use, "godot_tvos.xcframework");
			} else {
				ret = unzGoToNextFile(src_pkg_zip);
				continue; //ignore!
			}
		}

		if (file == project_file) {
			project_file_data = data;
		}

		///@TODO need to parse logo files

		if (data.size() > 0) {
			file = file.replace("godot_tvos", binary_name);

			print_line("ADDING: " + file + " size: " + itos(data.size()));

			/* write it into our folder structure */
			file = dest_dir + file;

			/* make sure this folder exists */
			String dir_name = file.get_base_dir();
			if (!tmp_app_path->dir_exists(dir_name)) {
				print_line("Creating " + dir_name);
				Error dir_err = tmp_app_path->make_dir_recursive(dir_name);
				if (dir_err) {
					ERR_PRINT("Can't create '" + dir_name + "'.");
					unzClose(src_pkg_zip);
					memdelete(tmp_app_path);
					return ERR_CANT_CREATE;
				}
			}

			/* write the file */
			FileAccess *f = FileAccess::open(file, FileAccess::WRITE);
			if (!f) {
				ERR_PRINT("Can't write '" + file + "'.");
				unzClose(src_pkg_zip);
				memdelete(tmp_app_path);
				return ERR_CANT_CREATE;
			};
			f->store_buffer(data.ptr(), data.size());
			f->close();
			memdelete(f);
		}

		ret = unzGoToNextFile(src_pkg_zip);
	}

	/* we're done with our source zip */
	unzClose(src_pkg_zip);
	if (ret != UNZ_END_OF_LIST_OF_FILE) {
		memdelete(tmp_app_path);
		return ERR_FILE_CORRUPT;
	}

	if (!found_library) {
		ERR_PRINT("Requested template library '" + library_to_use + "' not found. It might be missing from your template archive.");
		memdelete(tmp_app_path);
		return ERR_FILE_NOT_FOUND;
	}
	if (project_file_data.empty()) {
		ERR_PRINT("The tvOS template does not contain an Xcode project.");
		memdelete(tmp_app_path);
		return ERR_FILE_NOT_FOUND;
	}

	// Copy project static libs to the project
	Vector<Ref<EditorExportPlugin>> export_plugins = EditorExport::get_singleton()->get_export_plugins();
	for (int i = 0; i < export_plugins.size(); i++) {
		Vector<String> project_static_libs = export_plugins[i]->get_tvos_project_static_libs();
		for (int j = 0; j < project_static_libs.size(); j++) {
			const String &static_lib_path = project_static_libs[j];
			String dest_lib_file_path = dest_dir + static_lib_path.get_file();
			Error lib_copy_err = tmp_app_path->copy(static_lib_path, dest_lib_file_path);
			if (lib_copy_err != OK) {
				ERR_PRINT("Can't copy '" + static_lib_path + "'.");
				memdelete(tmp_app_path);
				return lib_copy_err;
			}
		}
	}

	print_line("Exporting additional assets");
	err = _export_additional_assets(dest_dir + binary_name, libraries, assets);
	if (err != OK) {
		memdelete(tmp_app_path);
		return err;
	}
	_add_assets_to_project(p_preset, project_file_data, assets);
	String project_file_name = dest_dir + binary_name + ".xcodeproj/project.pbxproj";
	FileAccess *f = FileAccess::open(project_file_name, FileAccess::WRITE);
	if (!f) {
		ERR_PRINT("Can't write '" + project_file_name + "'.");
		memdelete(tmp_app_path);
		return ERR_CANT_CREATE;
	};
	f->store_buffer(project_file_data.ptr(), project_file_data.size());
	f->close();
	memdelete(f);
	memdelete(tmp_app_path);

	return OK;
}

bool EditorExportPlatformTVOS::has_valid_export_configuration(
		const Ref<EditorExportPreset> &p_preset,
		String &r_error,
		bool &r_missing_templates) const {
	String err;
	bool valid = false;

	bool debug_valid = exists_export_template("tvos.zip", &err);
	bool release_valid = debug_valid; // Обе библиотеки лежат в одном ZIP.

	String custom_debug = p_preset->get("custom_template/debug");
	if (!custom_debug.empty()) {
		debug_valid = FileAccess::exists(custom_debug);

		if (!debug_valid) {
			err += TTR("Custom debug template not found.") + "\n";
		}
	}

	String custom_release = p_preset->get("custom_template/release");
	if (!custom_release.empty()) {
		release_valid = FileAccess::exists(custom_release);

		if (!release_valid) {
			err += TTR("Custom release template not found.") + "\n";
		}
	}

	valid = debug_valid || release_valid;
	r_missing_templates = !valid;

	if (!err.empty()) {
		r_error = err;
	}

	return valid;
}

bool EditorExportPlatformTVOS::has_valid_project_configuration(
		const Ref<EditorExportPreset> &p_preset,
		String &r_error) const {
	String err;
	bool valid = true;

	String team_id = p_preset->get("application/app_store_team_id");
	if (team_id.empty()) {
		err += TTR("App Store Team ID not specified - cannot configure the project.") + "\n";
		valid = false;
	}

	// В вашем tvOS-exporter параметр называется bundle_identifier,
	// а не application/identifier, как в новом iOS-exporter.
	String identifier = p_preset->get("application/bundle_identifier");
	String identifier_error;

	if (!is_package_name_valid(identifier, &identifier_error)) {
		err += TTR("Invalid Identifier:") + " " + identifier_error + "\n";
		valid = false;
	}

	String texture_error = test_etc2_or_pvrtc();
	if (!texture_error.empty()) {
		err += texture_error;
		valid = false;
	}

	if (!err.empty()) {
		r_error = err;
	}

	return valid;
}

EditorExportPlatformTVOS::EditorExportPlatformTVOS() {
	Ref<Image> img = memnew(Image(_tvos_logo));
	logo.instance();
	logo->create_from_image(img);

	plugins_changed.set();

	check_for_changes_thread.start(_check_for_changes_poll_thread, this);
}

EditorExportPlatformTVOS::~EditorExportPlatformTVOS() {
	quit_request.set();
	check_for_changes_thread.wait_to_finish();
}

void register_tvos_exporter() {
	Ref<EditorExportPlatformTVOS> platform;
	platform.instance();

	EditorExport::get_singleton()->add_export_platform(platform);
}
