// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "twilio_voice",
  platforms: [
    .macOS("11.0")
  ],
  products: [
    .library(name: "twilio-voice", targets: ["twilio_voice"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "twilio_voice",
      dependencies: [],
      resources: [
        // `index.html` is the page hosted by the plugin's WKWebView. `.process` flattens it into
        // the generated resource bundle, so it is looked up via `Bundle.module` - see TVWebView.
        .process("Resources")
      ]
    )
  ]
)
