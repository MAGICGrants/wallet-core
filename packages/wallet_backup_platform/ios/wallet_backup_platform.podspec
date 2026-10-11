#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'wallet_backup_platform'
  s.version          = '0.1.0'
  s.summary          = 'The metadata backup\'s iCloud location.'
  s.description      = <<-DESC
The app's iCloud Drive container as a location for the seed-keyed metadata
backup: coordinated reads and writes, NSMetadataQuery listing, upload status.
                       DESC
  s.homepage         = 'https://github.com/MAGICGrants/wallet-core'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'MAGIC Grants' => 'info@magicgrants.org' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
