#!/usr/bin/env python3
# Regenerates Stronghold.xcodeproj (project.pbxproj and shared schemes). Usage: scripts/generate-xcodeproj.py .
# Sources live in file-system-synchronized folders, so adding files does not need a regenerate; this is only
# for changing targets, build settings, package links or schemes.
import hashlib, os, sys
root = sys.argv[1]
def i(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()
ids = {k: i("stronghold." + k) for k in """PROJECT MAIN_GROUP PRODUCTS_GROUP CONFIG_GROUP APP_GROUP UIT_GROUP ENT_REF APP_PRODUCT UIT_PRODUCT
APP_TARGET UIT_TARGET APP_SRC APP_FW APP_RES UIT_SRC UIT_FW UIT_RES UIT_PROXY UIT_DEP
APP_ENGINE_BF APP_CORE_BF UIT_SUPPORT_BF APP_ENGINE_DEP APP_CORE_DEP UIT_SUPPORT_DEP LOCAL_ENGINE LOCAL_CORE
PROJ_LIST APP_LIST UIT_LIST PROJ_DEBUG PROJ_RELEASE APP_DEBUG APP_RELEASE UIT_DEBUG UIT_RELEASE""".split()}
I = ids

def settings(d, indent="\t\t\t\t"):
    out = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            out.append(f"{indent}{k} = (\n" + "".join(f"{indent}\t{q(x)},\n" for x in v) + f"{indent});")
        else:
            out.append(f"{indent}{k} = {q(v)};")
    return "\n".join(out)

def q(v):
    v = str(v)
    import re
    if re.fullmatch(r"[A-Za-z0-9_./]+", v) and v != "": return v
    return '"' + v.replace('"', '\\"') + '"'

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES", "COPY_PHASE_STRIP": "NO", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17", "GCC_NO_COMMON_BLOCKS": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES", "MACOSX_DEPLOYMENT_TARGET": "15.0", "SDKROOT": "macosx",
    "SWIFT_VERSION": "6.0", "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
}
proj_debug = dict(common, **{"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"], "ONLY_ACTIVE_ARCH": "YES", "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"})
proj_release = dict(common, **{"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule", "MTL_ENABLE_DEBUG_INFO": "NO"})
app = {"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
    "CODE_SIGN_ENTITLEMENTS": "Config/Stronghold.entitlements", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual",
    "COMBINE_HIDPI_IMAGES": "YES", "CURRENT_PROJECT_VERSION": "1", "DEVELOPMENT_TEAM": "", "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_PREVIEWS": "YES", "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "Stronghold", "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.developer-tools",
    "INFOPLIST_KEY_NSHumanReadableCopyright": "", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "MARKETING_VERSION": "0.1.0", "PRODUCT_BUNDLE_IDENTIFIER": "com.illumi.stronghold", "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "YES"}
uit = {"CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "CURRENT_PROJECT_VERSION": "1", "DEVELOPMENT_TEAM": "",
    "GENERATE_INFOPLIST_FILE": "YES", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
    "MARKETING_VERSION": "0.1.0", "PRODUCT_BUNDLE_IDENTIFIER": "com.illumi.stronghold.uitests", "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO", "TEST_TARGET_NAME": "Stronghold"}

def cfg(key, name, d):
    return f"\t\t{I[key]} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(d)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n"

def phase(key, isa, name, files=()):
    f = "".join(f"\t\t\t\t{I[x]} /* {n} */,\n" for x, n in files)
    return f"\t\t{I[key]} /* {name} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{f}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n"

def clist(key, name, d, r):
    return f"\t\t{I[key]} /* Build configuration list for {name} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{I[d]} /* Debug */,\n\t\t\t\t{I[r]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n"

def target(key, name, lst, phases, group, deps, pkgs, product, ptype):
    ph = "".join(f"\t\t\t\t{I[p]} /* {n} */,\n" for p, n in phases)
    dp = "".join(f"\t\t\t\t{I[d]} /* PBXTargetDependency */,\n" for d in deps)
    pk = "".join(f"\t\t\t\t{I[p]} /* {n} */,\n" for p, n in pkgs)
    return (f"\t\t{I[key]} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {I[lst]} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
            f"\t\t\tbuildPhases = (\n{ph}\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{dp}\t\t\t);\n"
            f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{I[group]} /* {name} */,\n\t\t\t);\n\t\t\tname = {name};\n"
            f"\t\t\tpackageProductDependencies = (\n{pk}\t\t\t);\n\t\t\tproductName = {name};\n"
            f"\t\t\tproductReference = {I[product]};\n\t\t\tproductType = \"{ptype}\";\n\t\t}};\n")

o = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n"
o += "/* Begin PBXBuildFile section */\n"
o += f"\t\t{I['APP_ENGINE_BF']} /* GitEngine in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['APP_ENGINE_DEP']} /* GitEngine */; }};\n"
o += f"\t\t{I['APP_CORE_BF']} /* StrongholdCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['APP_CORE_DEP']} /* StrongholdCore */; }};\n"
o += f"\t\t{I['UIT_SUPPORT_BF']} /* GitTestSupport in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['UIT_SUPPORT_DEP']} /* GitTestSupport */; }};\n"
o += "/* End PBXBuildFile section */\n\n/* Begin PBXContainerItemProxy section */\n"
o += f"\t\t{I['UIT_PROXY']} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {I['PROJECT']} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {I['APP_TARGET']};\n\t\t\tremoteInfo = Stronghold;\n\t\t}};\n"
o += "/* End PBXContainerItemProxy section */\n\n/* Begin PBXFileReference section */\n"
o += f"\t\t{I['APP_PRODUCT']} /* Stronghold.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Stronghold.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n"
o += f"\t\t{I['UIT_PRODUCT']} /* StrongholdUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = StrongholdUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n"
o += f"\t\t{I['ENT_REF']} /* Stronghold.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Stronghold.entitlements; sourceTree = \"<group>\"; }};\n"
o += f"\t\t{I['LOCAL_ENGINE']} /* GitEngine */ = {{isa = PBXFileReference; lastKnownFileType = wrapper; name = GitEngine; path = Packages/GitEngine; sourceTree = \"<group>\"; }};\n"
o += f"\t\t{I['LOCAL_CORE']} /* StrongholdCore */ = {{isa = PBXFileReference; lastKnownFileType = wrapper; name = StrongholdCore; path = Packages/StrongholdCore; sourceTree = \"<group>\"; }};\n"
o += "/* End PBXFileReference section */\n\n/* Begin PBXFileSystemSynchronizedRootGroup section */\n"
for k, p in (("APP_GROUP", "Stronghold"), ("UIT_GROUP", "StrongholdUITests")):
    o += f"\t\t{I[k]} /* {p} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {p};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
o += "/* End PBXFileSystemSynchronizedRootGroup section */\n\n/* Begin PBXFrameworksBuildPhase section */\n"
o += phase("APP_FW", "PBXFrameworksBuildPhase", "Frameworks", [("APP_ENGINE_BF", "GitEngine in Frameworks"), ("APP_CORE_BF", "StrongholdCore in Frameworks")])
o += phase("UIT_FW", "PBXFrameworksBuildPhase", "Frameworks", [("UIT_SUPPORT_BF", "GitTestSupport in Frameworks")])
o += "/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n"
o += f"\t\t{I['MAIN_GROUP']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{I['LOCAL_ENGINE']} /* GitEngine */,\n\t\t\t\t{I['LOCAL_CORE']} /* StrongholdCore */,\n\t\t\t\t{I['APP_GROUP']} /* Stronghold */,\n\t\t\t\t{I['UIT_GROUP']} /* StrongholdUITests */,\n\t\t\t\t{I['CONFIG_GROUP']} /* Config */,\n\t\t\t\t{I['PRODUCTS_GROUP']} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
o += f"\t\t{I['CONFIG_GROUP']} /* Config */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{I['ENT_REF']} /* Stronghold.entitlements */,\n\t\t\t);\n\t\t\tpath = Config;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
o += f"\t\t{I['PRODUCTS_GROUP']} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{I['APP_PRODUCT']} /* Stronghold.app */,\n\t\t\t\t{I['UIT_PRODUCT']} /* StrongholdUITests.xctest */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
o += "/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n"
o += target("APP_TARGET", "Stronghold", "APP_LIST", [("APP_SRC", "Sources"), ("APP_FW", "Frameworks"), ("APP_RES", "Resources")], "APP_GROUP", [], [("APP_ENGINE_DEP", "GitEngine"), ("APP_CORE_DEP", "StrongholdCore")], "APP_PRODUCT", "com.apple.product-type.application")
o += target("UIT_TARGET", "StrongholdUITests", "UIT_LIST", [("UIT_SRC", "Sources"), ("UIT_FW", "Frameworks"), ("UIT_RES", "Resources")], "UIT_GROUP", ["UIT_DEP"], [("UIT_SUPPORT_DEP", "GitTestSupport")], "UIT_PRODUCT", "com.apple.product-type.bundle.ui-testing")
o += "/* End PBXNativeTarget section */\n\n/* Begin PBXProject section */\n"
o += (f"\t\t{I['PROJECT']} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n"
      f"\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{I['APP_TARGET']} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t}};\n\t\t\t\t\t{I['UIT_TARGET']} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t\tTestTargetID = {I['APP_TARGET']};\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n"
      f"\t\t\tbuildConfigurationList = {I['PROJ_LIST']} /* Build configuration list for PBXProject \"Stronghold\" */;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
      f"\t\t\tmainGroup = {I['MAIN_GROUP']};\n\t\t\tminimizedProjectReferenceProxies = 1;\n"
      f"\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {I['PRODUCTS_GROUP']} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{I['APP_TARGET']} /* Stronghold */,\n\t\t\t\t{I['UIT_TARGET']} /* StrongholdUITests */,\n\t\t\t);\n\t\t}};\n")
o += "/* End PBXProject section */\n\n/* Begin PBXResourcesBuildPhase section */\n"
o += phase("APP_RES", "PBXResourcesBuildPhase", "Resources") + phase("UIT_RES", "PBXResourcesBuildPhase", "Resources")
o += "/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */\n"
o += phase("APP_SRC", "PBXSourcesBuildPhase", "Sources") + phase("UIT_SRC", "PBXSourcesBuildPhase", "Sources")
o += "/* End PBXSourcesBuildPhase section */\n\n/* Begin PBXTargetDependency section */\n"
o += f"\t\t{I['UIT_DEP']} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {I['APP_TARGET']} /* Stronghold */;\n\t\t\ttargetProxy = {I['UIT_PROXY']} /* PBXContainerItemProxy */;\n\t\t}};\n"
o += "/* End PBXTargetDependency section */\n\n/* Begin XCBuildConfiguration section */\n"
o += cfg("PROJ_DEBUG", "Debug", proj_debug) + cfg("PROJ_RELEASE", "Release", proj_release)
o += cfg("APP_DEBUG", "Debug", app) + cfg("APP_RELEASE", "Release", app)
o += cfg("UIT_DEBUG", "Debug", uit) + cfg("UIT_RELEASE", "Release", uit)
o += "/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n"
o += clist("PROJ_LIST", 'PBXProject "Stronghold"', "PROJ_DEBUG", "PROJ_RELEASE")
o += clist("APP_LIST", 'PBXNativeTarget "Stronghold"', "APP_DEBUG", "APP_RELEASE")
o += clist("UIT_LIST", 'PBXNativeTarget "StrongholdUITests"', "UIT_DEBUG", "UIT_RELEASE")
o += "/* End XCConfigurationList section */\n\n/* Begin XCSwiftPackageProductDependency section */\n"
for k, pkg, name in (("APP_ENGINE_DEP", "LOCAL_ENGINE", "GitEngine"), ("APP_CORE_DEP", "LOCAL_CORE", "StrongholdCore"), ("UIT_SUPPORT_DEP", "LOCAL_ENGINE", "GitTestSupport")):
    o += f"\t\t{I[k]} /* {name} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {name};\n\t\t}};\n"
o += "/* End XCSwiftPackageProductDependency section */\n\t};\n\trootObject = " + I['PROJECT'] + " /* Project object */;\n}\n"

proj = os.path.join(root, "Stronghold.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata/xcschemes"), exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w").write(o)

def ref(bid, name, product, container):
    return f'''<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{bid}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{container}">
            </BuildableReference>'''
app_ref = ref(I['APP_TARGET'], "Stronghold", "Stronghold.app", "Stronghold.xcodeproj")
def testable(r): return f'''         <TestableReference
            skipped = "NO">
            {r}
         </TestableReference>
'''
tests = testable(ref("GitEngineTests", "GitEngineTests", "GitEngineTests", "Packages/GitEngine")) + \
        testable(ref("StrongholdCoreTests", "StrongholdCoreTests", "StrongholdCoreTests", "Packages/StrongholdCore"))
ui_tests = testable(ref(I['UIT_TARGET'], "StrongholdUITests", "StrongholdUITests.xctest", "Stronghold.xcodeproj"))
def make_scheme(tests):
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "NO"
      codeCoverageEnabled = "YES">
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "ILLUMI_SCRIPTED"
            value = "1"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
      <Testables>
{tests}      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
open(os.path.join(proj, "xcshareddata/xcschemes/Stronghold.xcscheme"), "w").write(make_scheme(tests))
# UI tests need macOS Automation Mode, which an unattended session can't enable, so they get their own scheme.
open(os.path.join(proj, "xcshareddata/xcschemes/StrongholdUITests.xcscheme"), "w").write(make_scheme(ui_tests))
print("ok")
