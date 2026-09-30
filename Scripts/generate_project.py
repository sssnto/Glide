from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
if (root/'Glide.xcodeproj').exists():
    raise SystemExit('The Glide Xcode project already exists. Open it directly; regenerating would overwrite signing and release settings.')
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
deferred_monetization = {'ProStore.swift', 'ProView.swift'}
files=[p for p in sorted((root/'Glide').rglob('*.swift')) if p.name not in deferred_monetization]+sorted((root/'Glide/Resources').glob('*'))
# Resource list includes demo files generated in the next step.
files += [root/f'Glide/Resources/demo{i}.mp4' for i in range(3) if not (root/f'Glide/Resources/demo{i}.mp4') in files]
files += [root/'Glide/Assets.xcassets']
objects=[]
def obj(k,v): objects.append(f'{uid(k)} = {{ {v} }};')
refs=[]; sources=[]; resources=[]
for path in files:
 rel=str(path.relative_to(root)); k='file:'+rel; build='build:'+rel
 typ='sourcecode.swift' if path.suffix=='.swift' else ('folder.assetcatalog' if path.suffix=='.xcassets' else 'text.xml' if path.suffix=='.xcprivacy' else 'file')
 obj(k,f'isa = PBXFileReference; lastKnownFileType = {typ}; path = "{rel}"; sourceTree = SOURCE_ROOT;')
 obj(build,f'isa = PBXBuildFile; fileRef = {uid(k)};')
 refs.append(uid(k)); (sources if path.suffix=='.swift' else resources).append(uid(build))
obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = Glide.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products',f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
obj('main',f'isa = PBXGroup; children = ({",".join(refs+[uid("products")])}); sourceTree = "<group>";')
obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)}); runOnlyForDeploymentPostprocessing = 0;')
obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)}); runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug','Release']:
 obj('project'+mode,f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};')
 obj('target'+mode,f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; PRODUCT_NAME = Glide; PRODUCT_BUNDLE_IDENTIFIER = com.songpeng.glide; INFOPLIST_FILE = Glide/Info.plist; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = FR9RTRV9BC; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "{"-Onone" if mode=="Debug" else "-O"}"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{"DEBUG" if mode=="Debug" else ""}"; GENERATE_INFOPLIST_FILE = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; }};')
for kind in ['project','target']:
 obj(kind+'configs',f'isa = XCConfigurationList; buildConfigurations = ({uid(kind+"Debug")},{uid(kind+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")}); buildRules = (); dependencies = (); name = Glide; productName = Glide; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
obj('uitestfile', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/GlideUITests.swift; sourceTree = SOURCE_ROOT;')
obj('uitestbuild', f'isa = PBXBuildFile; fileRef = {uid("uitestfile")};')
obj('uitestproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = GlideUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('uitestsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("uitestbuild")}); runOnlyForDeploymentPostprocessing = 0;')
obj('proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = Glide;')
obj('dependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("proxy")};')
for mode in ['Debug', 'Release']:
 obj('uitest'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ PRODUCT_NAME = GlideUITests; PRODUCT_BUNDLE_IDENTIFIER = com.songpeng.glide.uitests; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = Glide; SWIFT_VERSION = 5.0; CODE_SIGN_STYLE = Automatic; TARGETED_DEVICE_FAMILY = "1,2"; }};')
obj('uitestconfigs', f'isa = XCConfigurationList; buildConfigurations = ({uid("uitestDebug")},{uid("uitestRelease")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('uitesttarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("uitestconfigs")}; buildPhases = ({uid("uitestsources")}); buildRules = (); dependencies = ({uid("dependency")}); name = GlideUITests; productName = GlideUITests; productReference = {uid("uitestproduct")}; productType = "com.apple.product-type.bundle.ui-testing";')
obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (en, Base, zh_CN); mainGroup = {uid("main")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},{uid("uitesttarget")});')
objects = [o.replace(f'children = ({uid("product")})', f'children = ({uid("product")},{uid("uitestproduct")})').replace(f'{uid("products")}); sourceTree', f'{uid("products")},{uid("uitestfile")}); sourceTree') for o in objects]
(root/'Glide.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
(root/'Glide.xcodeproj/xcshareddata/xcschemes/Glide.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Glide.app" BlueprintName="Glide" ReferencedContainer="container:Glide.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('uitesttarget')}" BuildableName="GlideUITests.xctest" BlueprintName="GlideUITests" ReferencedContainer="container:Glide.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Glide.app" BlueprintName="Glide" ReferencedContainer="container:Glide.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
