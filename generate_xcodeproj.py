#!/usr/bin/env python3
"""Generate a valid ReolinkClient.xcodeproj/project.pbxproj.

Run from the repo root:  python3 generate_xcodeproj.py
This keeps the project file in sync with the source tree without needing a Mac.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = "ReolinkClient"
BUNDLE_ID = "com.reolinkonmac.ReolinkClient"
SRC_DIR = os.path.join(ROOT, APP)

# Folder groups -> swift files within them (relative to the app dir).
GROUPS = {
    "": ["ReolinkClientApp.swift", "ContentView.swift"],
    "Models": ["Camera.swift", "CameraStream.swift", "CameraEvent.swift"],
    "Services": [
        "ReolinkAPIClient.swift", "RTSPURLBuilder.swift",
        "CameraDiscoveryService.swift", "KeychainService.swift",
        "SnapshotStore.swift", "MockMedia.swift",
    ],
    "ViewModels": ["CameraStore.swift", "CameraViewModel.swift"],
    "Views": [
        "CameraGridView.swift", "CameraTileView.swift", "CameraDetailView.swift",
        "AddCameraView.swift", "PTZControlView.swift", "EventListView.swift",
        "SettingsView.swift",
    ],
    "Video": ["RTSPPlayerView.swift", "VLCPlayerWrapper.swift"],
}
RESOURCES = ["Assets.xcassets"]
PLAIN_FILES = ["Info.plist", "ReolinkClient.entitlements"]


def oid(*parts):
    """Deterministic 24-char hex object id."""
    h = hashlib.sha1("::".join(parts).encode()).hexdigest().upper()
    return h[:24]


def main():
    lines = []
    file_refs = {}        # path -> fileRef id
    build_file_ids = {}   # path -> buildFile id

    # Collect all swift files (flat list with relative paths).
    swift_files = []
    for folder, names in GROUPS.items():
        for n in names:
            rel = f"{folder}/{n}" if folder else n
            swift_files.append(rel)

    for rel in swift_files + RESOURCES + PLAIN_FILES:
        file_refs[rel] = oid("ref", rel)
    for rel in swift_files + RESOURCES:
        build_file_ids[rel] = oid("build", rel)

    product_ref = oid("product")
    target_id = oid("target")
    project_id = oid("project")
    main_group = oid("maingroup")
    app_group = oid("appgroup")
    products_group = oid("products")
    src_phase = oid("srcphase")
    res_phase = oid("resphase")
    fw_phase = oid("fwphase")
    config_list_proj = oid("configlist_proj")
    config_list_tgt = oid("configlist_tgt")
    debug_proj = oid("debug_proj")
    release_proj = oid("release_proj")
    debug_tgt = oid("debug_tgt")
    release_tgt = oid("release_tgt")

    # Swift Package Manager: VLCKit (via tylerjonesio/vlckit-spm, product "VLCKitSPM").
    pkg_ref = oid("pkgref", "vlckit-spm")
    pkg_prod = oid("pkgprod", "VLCKitSPM")
    pkg_buildfile = oid("pkgbuild", "VLCKitSPM")

    group_ids = {folder: oid("group", folder) for folder in GROUPS if folder}

    w = lines.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # PBXBuildFile
    w("\n/* Begin PBXBuildFile section */")
    for rel in swift_files:
        name = os.path.basename(rel)
        w(f"\t\t{build_file_ids[rel]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[rel]} /* {name} */; }};")
    for rel in RESOURCES:
        w(f"\t\t{build_file_ids[rel]} /* {rel} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[rel]} /* {rel} */; }};")
    w(f"\t\t{pkg_buildfile} /* VLCKitSPM in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_prod} /* VLCKitSPM */; }};")
    w("/* End PBXBuildFile section */")

    # PBXFileReference
    w("\n/* Begin PBXFileReference section */")
    w(f'\t\t{product_ref} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{APP}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    for rel in swift_files:
        name = os.path.basename(rel)
        w(f'\t\t{file_refs[rel]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>"; }};')
    for rel in RESOURCES:
        w(f'\t\t{file_refs[rel]} /* {rel} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "{rel}"; sourceTree = "<group>"; }};')
    w(f'\t\t{file_refs["Info.plist"]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    w(f'\t\t{file_refs["ReolinkClient.entitlements"]} /* {APP}.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "{APP}.entitlements"; sourceTree = "<group>"; }};')
    w("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    w("\n/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{fw_phase} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w(f"\t\t\t\t{pkg_buildfile} /* VLCKitSPM in Frameworks */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    w("\n/* Begin PBXGroup section */")
    # main group
    w(f"\t\t{main_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{app_group} /* {APP} */,")
    w(f"\t\t\t\t{products_group} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    # products group
    w(f"\t\t{products_group} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{product_ref} /* {APP}.app */,")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    # app group (root files + subgroups + resources + plist)
    w(f"\t\t{app_group} /* {APP} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for n in GROUPS[""]:
        w(f"\t\t\t\t{file_refs[n]} /* {n} */,")
    for folder in GROUPS:
        if folder:
            w(f"\t\t\t\t{group_ids[folder]} /* {folder} */,")
    for rel in RESOURCES:
        w(f"\t\t\t\t{file_refs[rel]} /* {rel} */,")
    w(f"\t\t\t\t{file_refs['Info.plist']} /* Info.plist */,")
    w(f"\t\t\t\t{file_refs['ReolinkClient.entitlements']} /* {APP}.entitlements */,")
    w("\t\t\t);")
    w(f'\t\t\tpath = {APP};')
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    # subgroups
    for folder, names in GROUPS.items():
        if not folder:
            continue
        w(f"\t\t{group_ids[folder]} /* {folder} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for n in names:
            rel = f"{folder}/{n}"
            w(f"\t\t\t\t{file_refs[rel]} /* {n} */,")
        w("\t\t\t);")
        w(f'\t\t\tpath = {folder};')
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")
    w("/* End PBXGroup section */")

    # PBXNativeTarget
    w("\n/* Begin PBXNativeTarget section */")
    w(f"\t\t{target_id} /* {APP} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {config_list_tgt} /* Build configuration list for PBXNativeTarget \"{APP}\" */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{src_phase} /* Sources */,")
    w(f"\t\t\t\t{fw_phase} /* Frameworks */,")
    w(f"\t\t\t\t{res_phase} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w(f'\t\t\tname = {APP};')
    w("\t\t\tpackageProductDependencies = (")
    w(f"\t\t\t\t{pkg_prod} /* VLCKitSPM */,")
    w("\t\t\t);")
    w(f'\t\t\tproductName = {APP};')
    w(f"\t\t\tproductReference = {product_ref} /* {APP}.app */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # PBXProject
    w("\n/* Begin PBXProject section */")
    w(f"\t\t{project_id} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1530;")
    w("\t\t\t\tLastUpgradeCheck = 1530;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target_id} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.3;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {config_list_proj} /* Build configuration list for PBXProject \"{APP}\" */;")
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group};")
    w(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tpackageReferences = (")
    w(f"\t\t\t\t{pkg_ref} /* XCRemoteSwiftPackageReference \"vlckit-spm\" */,")
    w("\t\t\t);")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target_id} /* {APP} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # PBXResourcesBuildPhase
    w("\n/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{res_phase} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for rel in RESOURCES:
        w(f"\t\t\t\t{build_file_ids[rel]} /* {rel} in Resources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # PBXSourcesBuildPhase
    w("\n/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{src_phase} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for rel in swift_files:
        name = os.path.basename(rel)
        w(f"\t\t\t\t{build_file_ids[rel]} /* {name} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # XCBuildConfiguration
    def project_settings(config):
        debug = config == "Debug"
        s = [
            "ALWAYS_SEARCH_USER_PATHS = NO;",
            "CLANG_ANALYZER_NONNULL = YES;",
            "CLANG_ENABLE_MODULES = YES;",
            "CLANG_ENABLE_OBJC_ARC = YES;",
            "COPY_PHASE_STRIP = NO;",
            "ENABLE_STRICT_OBJC_MSGSEND = YES;",
            "GCC_C_LANGUAGE_STANDARD = gnu17;",
            "GCC_NO_COMMON_BLOCKS = YES;",
            "MACOSX_DEPLOYMENT_TARGET = 14.0;",
            "SDKROOT = macosx;",
            "SWIFT_VERSION = 5.0;",
        ]
        if debug:
            s += [
                "DEBUG_INFORMATION_FORMAT = dwarf;",
                "ENABLE_TESTABILITY = YES;",
                "GCC_OPTIMIZATION_LEVEL = 0;",
                "GCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\");",
                "ONLY_ACTIVE_ARCH = YES;",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";",
                "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
            ]
        else:
            s += [
                "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";",
                "ENABLE_NS_ASSERTIONS = NO;",
                "SWIFT_COMPILATION_MODE = wholemodule;",
            ]
        return s

    def target_settings():
        return [
            "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
            f'CODE_SIGN_ENTITLEMENTS = "{APP}/{APP}.entitlements";',
            "CODE_SIGN_STYLE = Automatic;",
            "COMBINE_HIDPI_IMAGES = YES;",
            "CURRENT_PROJECT_VERSION = 1;",
            "ENABLE_HARDENED_RUNTIME = YES;",
            "GENERATE_INFOPLIST_FILE = NO;",
            f'INFOPLIST_FILE = "{APP}/Info.plist";',
            "INFOPLIST_KEY_LSApplicationCategoryType = \"public.app-category.utilities\";",
            "INFOPLIST_KEY_NSHumanReadableCopyright = \"\";",
            'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks");',
            "MARKETING_VERSION = 1.0;",
            f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";',
            "PRODUCT_NAME = \"$(TARGET_NAME)\";",
            "SWIFT_EMIT_LOC_STRINGS = YES;",
        ]

    w("\n/* Begin XCBuildConfiguration section */")
    for cfg_id, name, is_proj in [
        (debug_proj, "Debug", True), (release_proj, "Release", True),
        (debug_tgt, "Debug", False), (release_tgt, "Release", False),
    ]:
        w(f"\t\t{cfg_id} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        settings = project_settings(name) if is_proj else target_settings()
        for line in settings:
            w(f"\t\t\t\t{line}")
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    w("/* End XCBuildConfiguration section */")

    # XCConfigurationList
    w("\n/* Begin XCConfigurationList section */")
    w(f"\t\t{config_list_proj} /* Build configuration list for PBXProject \"{APP}\" */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{debug_proj} /* Debug */,")
    w(f"\t\t\t\t{release_proj} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w(f"\t\t{config_list_tgt} /* Build configuration list for PBXNativeTarget \"{APP}\" */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{debug_tgt} /* Debug */,")
    w(f"\t\t\t\t{release_tgt} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w("/* End XCConfigurationList section */")

    # XCRemoteSwiftPackageReference
    w("\n/* Begin XCRemoteSwiftPackageReference section */")
    w(f'\t\t{pkg_ref} /* XCRemoteSwiftPackageReference "vlckit-spm" */ = {{')
    w("\t\t\tisa = XCRemoteSwiftPackageReference;")
    w('\t\t\trepositoryURL = "https://github.com/tylerjonesio/vlckit-spm.git";')
    w("\t\t\trequirement = {")
    w("\t\t\t\tkind = exactVersion;")
    w("\t\t\t\tversion = 3.5.1;")
    w("\t\t\t};")
    w("\t\t};")
    w("/* End XCRemoteSwiftPackageReference section */")

    # XCSwiftPackageProductDependency
    w("\n/* Begin XCSwiftPackageProductDependency section */")
    w(f"\t\t{pkg_prod} /* VLCKitSPM */ = {{")
    w("\t\t\tisa = XCSwiftPackageProductDependency;")
    w(f'\t\t\tpackage = {pkg_ref} /* XCRemoteSwiftPackageReference "vlckit-spm" */;')
    w("\t\t\tproductName = VLCKitSPM;")
    w("\t\t};")
    w("/* End XCSwiftPackageProductDependency section */")

    w("\t};")
    w(f"\trootObject = {project_id} /* Project object */;")
    w("}")

    proj_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(lines) + "\n")

    # Minimal shared scheme so the app is runnable immediately.
    scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    with open(os.path.join(scheme_dir, f"{APP}.xcscheme"), "w") as f:
        f.write(SCHEME.format(app=APP, target_id=target_id, project=os.path.basename(proj_dir)))

    print(f"Wrote {proj_dir}/project.pbxproj with {len(swift_files)} sources.")


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1530" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{app}.app" BlueprintName="{app}" ReferencedContainer="container:{project}"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{app}.app" BlueprintName="{app}" ReferencedContainer="container:{project}"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{app}.app" BlueprintName="{app}" ReferencedContainer="container:{project}"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""


if __name__ == "__main__":
    main()
