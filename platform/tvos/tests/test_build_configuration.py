"""Exercise the actual SCons configuration without requiring an Apple SDK.

Run from the repository root with:
    python -m unittest discover -s platform/tvos/tests -p 'test_build_configuration.py'
"""

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from SCons.Environment import Environment


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
import methods

spec = importlib.util.spec_from_file_location("tvos_detect", ROOT / "platform/tvos/detect.py")
detect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(detect)


class TVOSBuildConfigurationTests(unittest.TestCase):
    def environment(self, arch="arm64", simulator=False, **overrides):
        env = Environment(
            tools=[],
            target="release_debug",
            optimize="speed",
            lto="auto",
            arch=arch,
            bits="default",
            simulator=simulator,
            TVOSPATH="/Toolchains/XcodeDefault.xctoolchain",
            TVOSSDK="/SDKs/AppleTV.sdk",
            tvos_triple="",
        )
        env["tools"] = False
        env["ENV"]["PATH"] = "/usr/bin"
        env.extra_suffix = ""
        env.Replace(**overrides)
        return env

    def test_device_and_simulator_target_distinct_apple_platforms(self):
        cases = [
            ("arm64", False, "arm64-apple-tvos15.0", "tvos", ""),
            ("arm64", True, "arm64-apple-tvos15.0-simulator", "tvossimulator", ".simulator"),
            ("x86_64", True, "x86_64-apple-tvos15.0-simulator", "tvossimulator", ".simulator"),
        ]
        for arch, simulator, target, sdk, suffix in cases:
            with self.subTest(arch=arch, simulator=simulator):
                env = self.environment(arch, simulator)
                with patch.object(detect, "detect_darwin_sdk_path") as sdk_path:
                    detect.configure(env)
                sdk_path.assert_called_once_with(sdk, env)
                for flag_kind in ["CCFLAGS", "ASFLAGS", "LINKFLAGS"]:
                    flags = env.subst_list("$" + flag_kind)[0]
                    self.assertEqual(flags[flags.index("-target") + 1], target)
                    self.assertEqual(flags[flags.index("-isysroot") + 1], "/SDKs/AppleTV.sdk")
                    self.assertNotIn("-fembed-bitcode", flags)
                    self.assertNotIn("-bitcode_bundle", flags)
                self.assertEqual(env.extra_suffix, suffix)
                self.assertEqual(env["bits"], "64")

    def test_invalid_architectures_fail_before_sdk_lookup(self):
        for overrides in [
            {"arch": "x86_64"},
            {"arch": "x86"},
            {"arch": "armv7"},
            {"bits": "32"},
            {"tools": True},
        ]:
            with self.subTest(overrides=overrides):
                env = self.environment(**overrides)
                with patch.object(detect, "detect_darwin_sdk_path") as sdk_path:
                    with self.assertRaises(ValueError):
                        detect.configure(env)
                    sdk_path.assert_not_called()

    def test_default_architecture_and_extra_suffix(self):
        env = self.environment(arch="", simulator=True)
        env.extra_suffix = ".custom"
        with patch.object(detect, "detect_darwin_sdk_path"):
            detect.configure(env)
        self.assertEqual(env["arch"], "arm64")
        self.assertEqual(env.extra_suffix, ".simulator.custom")
        self.assertEqual(env["lto"], "none")

    def test_apple_sdk_queries_use_tvos_names(self):
        for platform, sdk in [("tvos", "appletvos"), ("tvossimulator", "appletvsimulator")]:
            with self.subTest(platform=platform):
                env = {"TVOSSDK": ""}
                with patch.object(methods.subprocess, "check_output", return_value=b"/SDKs/Selected.sdk\n") as run:
                    methods.detect_darwin_sdk_path(platform, env)
                run.assert_called_once_with(["xcrun", "--sdk", sdk, "--show-sdk-path"])
                self.assertEqual(env["TVOSSDK"], "/SDKs/Selected.sdk")
                with patch.object(methods.subprocess, "check_output", return_value=b"18.2\n") as run:
                    self.assertEqual(methods.get_darwin_sdk_version(platform), 18.2)
                run.assert_called_once_with(["xcrun", "--sdk", sdk, "--show-sdk-version"])

    def test_explicit_sdk_path_is_preserved(self):
        env = {"TVOSSDK": "/custom/AppleTV.sdk"}
        with patch.object(methods.subprocess, "check_output") as run:
            methods.detect_darwin_sdk_path("tvossimulator", env)
        run.assert_not_called()
        self.assertEqual(env["TVOSSDK"], "/custom/AppleTV.sdk")

    def test_old_sdk_is_rejected(self):
        with patch.object(detect.sys, "platform", "darwin"):
            with patch.object(detect, "get_darwin_sdk_version", return_value=14.5):
                self.assertFalse(detect.can_build())
            with patch.object(detect, "get_darwin_sdk_version", return_value=15.0):
                self.assertTrue(detect.can_build())


if __name__ == "__main__":
    unittest.main()
