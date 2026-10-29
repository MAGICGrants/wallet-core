#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'wallet_backup_platform'
  s.version          = '0.1.0'
  s.summary          = 'The metadata backup\'s sync folder bookmark on macOS.'
  s.description      = <<-DESC
Keeps the folder the user chose for the metadata backup as a security-scoped
bookmark, so the sandboxed app can open it again at every launch.
                       DESC
  s.homepage         = 'https://github.com/MAGICGrants/wallet-core'
  s.license          = { :type => 'MIT' }
  s.author           = { 'MAGIC Grants' => 'info@magicgrants.org' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '13.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
