Pod::Spec.new do |s|
  s.name = 'TelemetryBridge'
  s.version = '1.0.0'
  s.summary = 'Codegen TurboModule and shared native telemetry storage.'
  s.homepage = 'https://github.com/ajkhatibi/rn-swiftui-turbo-bridge'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Julian Khatibi'
  s.source = { :git => 'https://github.com/ajkhatibi/rn-swiftui-turbo-bridge.git', :tag => s.version.to_s }
  s.platform = :ios, '16.2'
  s.swift_version = '5.9'
  s.module_name = 'TelemetryBridge'
  s.source_files = 'ios/Bridge/*.{swift,m}', 'ios/Shared/*.swift'
  s.frameworks = 'ActivityKit', 'WidgetKit', 'Security'
  s.compiler_flags = '-x objective-c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'SWIFT_OBJC_INTERFACE_HEADER_NAME' => 'TelemetryBridge-Swift.h',
    'SWIFT_INSTALL_OBJC_HEADER' => 'YES'
  }
  install_modules_dependencies(s)
end
