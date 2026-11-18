import os
import sys
from methods import detect_darwin_sdk_path, get_darwin_sdk_version


TVOS_MIN_VERSION = "15.0"


def is_active():
    return True


def get_name():
    return "tvOS"


def can_build():
    if sys.platform == "darwin":
        if get_darwin_sdk_version("tvos") < float(TVOS_MIN_VERSION):
            print("Detected tvOS SDK version older than " + TVOS_MIN_VERSION)
            return False
        return True
    return "OSXCROSS_TVOS" in os.environ


def get_opts():
    from SCons.Variables import BoolVariable

    return [
        (
            "TVOSPATH",
            "Path to tvOS toolchain",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
        ),
        ("TVOSSDK", "Path to the tvOS SDK", ""),
        BoolVariable("simulator", "Build for the tvOS Simulator", False),
        ("tvos_triple", "Prefix for the tvOS cross toolchain", ""),
    ]


def get_flags():
    return [("tools", False)]


def configure(env):
    # tvOS builds export templates; the editor is built for a desktop platform.
    if env["tools"]:
        raise ValueError("The tvOS platform requires tools=no.")
    if env["bits"] == "32":
        raise ValueError("tvOS supports only 64-bit architectures.")
    if env["arch"] not in ["", "arm64", "x86_64"]:
        raise ValueError("Unsupported tvOS architecture: " + env["arch"])
    if not env["arch"]:
        env["arch"] = "arm64"
    if env["arch"] == "x86_64" and not env["simulator"]:
        raise ValueError("Building tvOS for arch=x86_64 requires simulator=yes.")
    env["bits"] = "64"

    # Build type. Shared debug/assertion defines are configured by SConstruct.
    if env["target"].startswith("release"):
        env.Append(CPPDEFINES=[("NS_BLOCK_ASSERTIONS", 1)])
        if env["optimize"] == "speed":
            # Preserve useful backtraces in the debug export template.
            opt = "-O3" if env["target"] == "release" else "-O2"
            env.Append(CCFLAGS=[opt], LINKFLAGS=[opt])
        elif env["optimize"] == "size":
            env.Append(CCFLAGS=["-Os"], LINKFLAGS=["-Os"])
    elif env["target"] == "debug":
        env.Append(CCFLAGS=["-g", "-O0"])

    if env["lto"] == "auto":
        env["lto"] = "none"
    if env["lto"] != "none":
        lto_flag = "-flto=thin" if env["lto"] == "thin" else "-flto"
        env.Append(CCFLAGS=[lto_flag], LINKFLAGS=[lto_flag])

    if "OSXCROSS_TVOS" in os.environ:
        env["osxcross"] = True

    sdk = "tvossimulator" if env["simulator"] else "tvos"
    detect_darwin_sdk_path(sdk, env)
    compiler_path = "$TVOSPATH/usr/bin/${tvos_triple}"
    cache = os.environ.get("CCACHE", "")
    cache_prefix = cache + " " if cache else ""
    env["CC"] = cache_prefix + compiler_path + "clang"
    env["CXX"] = cache_prefix + compiler_path + "clang++"
    env["AS"] = env["CC"]
    env["ASCOM"] = "$AS $ASFLAGS -c -o $TARGET $SOURCES"
    env["AR"] = compiler_path + "ar"
    env["RANLIB"] = compiler_path + "ranlib"
    env["ENV"]["PATH"] = env["TVOSPATH"] + "/usr/bin/" + os.pathsep + env["ENV"]["PATH"]

    # Explicit triples distinguish Apple Silicon simulator objects from arm64
    # device objects even when both are built on the same Mac.
    target = env["arch"] + "-apple-tvos" + TVOS_MIN_VERSION
    if env["simulator"]:
        target += "-simulator"
        env.extra_suffix = ".simulator" + env.extra_suffix
    target_flags = ["-target", target, "-isysroot", "$TVOSSDK"]
    env.Append(CCFLAGS=target_flags, ASFLAGS=target_flags, LINKFLAGS=target_flags)
    env.Append(
        CCFLAGS=[
            "-fobjc-arc",
            "-fmessage-length=0",
            "-fno-strict-aliasing",
            "-fblocks",
            "-fvisibility=hidden",
            "-Wno-ambiguous-macro",
        ],
        LINKFLAGS=["-Wl,-dead_strip"],
    )
    if env["arch"] == "arm64":
        env.Append(CPPDEFINES=["NEED_LONG_INT", "LIBYUV_DISABLE_NEON"])

    # Bitcode was removed from the modern App Store/Xcode workflow.
    # Do not add -fembed-bitcode or -bitcode_bundle for either SDK.
    env.Prepend(
        CPPPATH=[
            "#platform/tvos",
            "$TVOSSDK/usr/include",
            "$TVOSSDK/System/Library/Frameworks/OpenGLES.framework/Headers",
            "$TVOSSDK/System/Library/Frameworks/AudioUnit.framework/Headers",
        ]
    )
    env.Append(
        CPPDEFINES=["TVOS_ENABLED", "UNIX_ENABLED", "GLES_ENABLED", "COREAUDIO_ENABLED", "GLES_SILENCE_DEPRECATION"]
    )
