// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "twilio_voice",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "twilio-voice", targets: ["twilio_voice"])
  ],
  dependencies: [
    // Mirrors the `TwilioVoice` CocoaPods dependency in `ios/twilio_voice.podspec`. Keep the two
    // version constraints in step so an app gets the same SDK whichever integration it uses.
    .package(url: "https://github.com/twilio/twilio-voice-ios", from: "6.13.6")
  ],
  targets: [
    .target(
      name: "twilio_voice",
      dependencies: [
        // The dynamic variant, matching what the CocoaPods integration vendors. Twilio also
        // publishes `TwilioVoice-static`, which additionally requires SystemConfiguration.
        .product(name: "TwilioVoice", package: "twilio-voice-ios")
      ]
    )
  ]
)
