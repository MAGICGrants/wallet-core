#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'wallet_fhse'
  s.version          = '0.1.0'
  s.summary          = 'FHSE (FIDO2 hmac-secret encryption) for wallet files.'
  s.description      = <<-DESC
No sources of its own. The C library is fhse_native's pod, and the Swift half
(apple/) is compiled by each app. This pod exists because Flutter only links a
plugin with a native build into the app, and the apps compile apple/ through
that link (see apple/README.md).
                       DESC
  s.homepage         = 'https://github.com/MAGICGrants/wallet-core'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'MAGIC Grants' => 'info@magicgrants.org' }

  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '13.0'
end
