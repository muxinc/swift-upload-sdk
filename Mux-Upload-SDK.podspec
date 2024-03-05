Pod::Spec.new do |s|
  s.name             = 'Mux-Upload-SDK'
  s.module_name      = 'MuxUploadSDK'
  s.version          = '0.6.0'
  s.summary          = 'Upload video to Mux.'
  s.description      = 'A library for uploading video to Mux. Similar to UpChunk, but for iOS.'

  s.homepage         = 'https://github.com/muxinc/swift-upload-sdk'
  s.license          = 'Apache 2.0'
  s.author           = { 'Mux' => 'ios-sdk@mux.com' }
  s.source           = { :git => 'https://github.com/muxinc/swift-upload-sdk.git', :tag => "v#{s.version}" }
  s.social_media_url = 'https://twitter.com/muxhq'

  s.swift_version = '5.0'

  s.ios.deployment_target = '14.0'
  s.macos.deployment_target = '13.0'

  s.source_files = 'Sources/MuxUploadSDK/**/*'
end
