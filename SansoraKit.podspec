# Sansora iOS SDK. Not on CocoaPods trunk (read-only from December 2026): apps take it
# from the sansora-swift repository, which sdks/ios/Scripts/export-package.sh writes
# (docs/SDK-RELEASING.md). Paths are relative to this folder, so it works from both:
#   pod 'SansoraKit', :git => 'https://github.com/Sansa-Organisation/sansora-swift.git', :tag => '0.2.0'
#   pod 'SansoraKit', :path => '<checkout>/sdks/ios'
Pod::Spec.new do |s|
  s.name             = 'SansoraKit'
  s.version          = '0.2.0'
  s.summary          = 'Native remote paywalls, placements and events for Sansora.'
  s.description      = 'Downloads sansora.config/1, resolves placements, draws paywalls natively with SwiftUI, buys with StoreKit 2 and delivers sansora.event/1 events.'
  s.homepage         = 'https://sansora.my'
  s.license          = { :type => 'Sansora SDK License', :file => 'LICENSE' }
  s.author           = { 'Sansora' => 'support@sansavision.com' }
  s.source           = { :git => 'https://github.com/Sansa-Organisation/sansora-swift.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9', '6.0']
  s.source_files     = 'Sources/SansoraKit/**/*.swift'
  s.frameworks       = 'Foundation', 'SwiftUI', 'UIKit', 'StoreKit', 'CryptoKit', 'SafariServices'
end
