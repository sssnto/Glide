# Generates a disposable project sharing Glide's pinned SDK and playback adapter.
require 'xcodeproj'
require 'fileutils'
root = File.expand_path('../..', __dir__)
work, framework = ARGV.map { |v| File.expand_path(v) }
abort 'Usage: generate_project.rb WORK XCFRAMEWORK' unless work && framework && File.directory?(framework)
path = File.join(work, 'CompatibilityLab.xcodeproj')
FileUtils.rm_rf(path) if File.directory?(path)
project = Xcodeproj::Project.new(path)
app = project.new_target(:application, 'CompatibilityLab', :ios, '17.0')
ui = project.new_target(:ui_test_bundle, 'CompatibilityLabUITests', :ios, '17.0')
ui.add_dependency(app)
compatibility = File.join(root, 'Glide/Services/Compatibility')
sources = Dir.glob(File.join(root, 'Glide/Core/*.swift')) + ['Glide/Services/PlaybackEngine.swift', 'Glide/Services/PlaybackResource.swift', 'Glide/Services/PlaybackAudioSession.swift'].map { |p| File.join(root,p) } + Dir.glob(File.join(__dir__, '*.swift')) + [File.join(compatibility, 'VLCPlaybackEngine.swift')]
sources.each { |p| app.source_build_phase.add_file_reference(project.main_group.new_file(p)) }
Dir.glob(File.join(compatibility, '*.m')).each { |p| app.source_build_phase.add_file_reference(project.main_group.new_file(p)) }
ui.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, 'UITests/CompatibilityLabUITests.swift')))
ref = project.main_group.new_file(framework)
app.frameworks_build_phase.add_file_reference(ref)
embed = app.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10'
build_file = embed.add_file_reference(ref)
build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
validation = app.new_shell_script_build_phase('Validate Embedded SDK')
validation.input_paths = ['$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/MobileVLCKit.framework/MobileVLCKit']
validation.shell_script = 'test -s "$SCRIPT_INPUT_FILE_0" || { echo "error: Candidate SDK missing from app bundle"; exit 1; }'
validation.always_out_of_date = '1'
%w[QuartzCore CoreText AVFoundation Security CFNetwork AudioToolbox OpenGLES CoreGraphics VideoToolbox CoreMedia].each { |name| app.add_system_framework(name) }
%w[c++ xml2 z bz2 iconv].each { |name| app.add_system_library(name) }
[app,ui].each do |target|
 target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => target == app ? 'com.songpeng.glide.compatibilitylab' : 'com.songpeng.glide.compatibilitylab.uitests',
    'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TARGETED_DEVICE_FAMILY' => '1,2',
    'CODE_SIGN_STYLE' => 'Automatic', 'CODE_SIGNING_ALLOWED' => 'NO',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES', 'CLANG_ENABLE_MODULES' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'OTHER_LDFLAGS' => ['$(inherited)', '-ObjC'], 'MARKETING_VERSION' => '0.1', 'CURRENT_PROJECT_VERSION' => '1'
  })
 end
end
app.build_configurations.each do |config|
 config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = File.join(compatibility, 'VLCClockPlayer.h')
 config.build_settings.merge!({'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES', 'INFOPLIST_KEY_CFBundleDisplayName' => 'Glide 兼容验证'})
end
ui.build_configurations.each { |c| c.build_settings['TEST_TARGET_NAME'] = 'CompatibilityLab' }
fixture = File.join(work, 'Fixtures')
FileUtils.mkdir_p(fixture)
fixture_source = ENV.fetch('GLIDE_LAB_FIXTURES', '/tmp/Glide121/FormatFixtures')
abort 'Generate fixtures first and set GLIDE_LAB_FIXTURES' unless File.file?(File.join(fixture_source, 'manifest.json'))
FileUtils.cp_r(Dir.glob(File.join(fixture_source, '*')), fixture)
resource = project.main_group.new_file(fixture)
resource.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(resource)
font_resource = project.main_group.new_file(File.join(root, 'Glide/Resources/SubtitleFonts'))
font_resource.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(font_resource)
app.resources_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Glide/Resources/SubtitleFont-OFL.txt')))
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(ui)
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(path, 'CompatibilityLab', true)
puts path
