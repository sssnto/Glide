require 'xcodeproj'
abort 'CommerceLab.xcodeproj already exists; open it instead of regenerating.' if File.exist?('CommerceLab.xcodeproj')
project = Xcodeproj::Project.new('CommerceLab.xcodeproj')
app = project.new_target(:application, 'CommerceLab', :ios, '17.0')
tests = project.new_target(:unit_test_bundle, 'CommerceLabTests', :ios, '17.0')
tests.add_dependency(app)
app_group = project.main_group.new_group('CommerceLab', 'CommerceLab')
test_group = project.main_group.new_group('CommerceLabTests', 'CommerceLabTests')
app.source_build_phase.add_file_reference(app_group.new_file('App.swift'))
app.source_build_phase.add_file_reference(project.main_group.new_file('../../Glide/Services/ProStore.swift'))
tests.source_build_phase.add_file_reference(test_group.new_file('CommerceLabTests.swift'))
tests.resources_build_phase.add_file_reference(test_group.new_file('Glide.storekit'))
project.build_configurations.each { |c| c.build_settings['SWIFT_VERSION'] = '5.0' }
app.build_configurations.each do |c|
  c.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'com.songpeng.glide.commercelab', 'GENERATE_INFOPLIST_FILE' => 'YES', 'SWIFT_VERSION' => '5.0', 'TARGETED_DEVICE_FAMILY' => '1,2', 'CODE_SIGNING_ALLOWED' => 'NO')
end
tests.build_configurations.each do |c|
  c.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'com.songpeng.glide.commercelab.tests', 'GENERATE_INFOPLIST_FILE' => 'YES', 'SWIFT_VERSION' => '5.0', 'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/CommerceLab.app/CommerceLab', 'BUNDLE_LOADER' => '$(TEST_HOST)', 'CODE_SIGNING_ALLOWED' => 'NO')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as('CommerceLab.xcodeproj', 'CommerceLab', true)
scheme_path = 'CommerceLab.xcodeproj/xcshareddata/xcschemes/CommerceLab.xcscheme'
scheme_xml = File.read(scheme_path)
scheme_xml.sub!('</LaunchAction>', "  <StoreKitConfigurationFileReference identifier=\"../CommerceLabTests/Glide.storekit\"/>\n   </LaunchAction>")
File.write(scheme_path, scheme_xml)
