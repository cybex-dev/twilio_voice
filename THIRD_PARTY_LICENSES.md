# Third-party licenses

The `twilio_voice` package is distributed under the MIT license (see [LICENSE](LICENSE)). It also
**redistributes third-party software**, listed below. Those files remain under their own licenses,
and the notices below apply to them rather than to the MIT license of this package.

---

## Twilio Voice JS SDK (`twilio.min.js`)

The Twilio Voice JavaScript SDK is bundled with this package so that the web and macOS
implementations load the exact SDK version they were developed and tested against, without
requiring a CDN or a manual copy step.

The SDK is bundled **once**, as a Flutter asset shared by both platforms that need it:

- `assets/twilio.min.js`
  - **web** — served at `assets/packages/twilio_voice/assets/twilio.min.js` and injected on demand.
  - **macOS** — read from the Flutter asset bundle and injected into the plugin's hidden
    `WKWebView` as a `WKUserScript` (see `TVWebView.injectTwilioVoiceSDK()`).

It is an unmodified redistribution of the official
[`@twilio/voice-sdk`](https://www.npmjs.com/package/@twilio/voice-sdk) distribution build.

**Bundled version: 2.18.0**

- Project: https://github.com/twilio/twilio-voice.js
- License: Apache License, Version 2.0
- Full license text (including the third-party notices reproduced below):
  https://github.com/twilio/twilio-voice.js/blob/master/LICENSE.md

```
The following license applies to all parts of this software except as
documented below.

Copyright (C) 2015-2026 Twilio, inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

A copy of the Apache License, Version 2.0 is available at
http://www.apache.org/licenses/LICENSE-2.0

### Components bundled inside the Twilio Voice JS SDK

The Twilio Voice JS SDK distribution itself includes the following third-party components, whose
notices are reproduced here as required by their licenses. See the SDK's `LICENSE.md` (linked
above) for the complete, authoritative text.

#### rtcpeerconnection-shim — BSD 3-Clause

```
Copyright (c) 2017 Philipp Hancke. All rights reserved.
Copyright (c) 2014, The WebRTC project authors. All rights reserved.
```

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the conditions of the BSD 3-Clause license are met, including retention of the above
copyright notices, this list of conditions and the following disclaimer, and the restriction that
the names of the copyright holders/contributors may not be used to endorse or promote derived
products without specific prior written permission.

#### backoff — MIT

```
Copyright (C) 2012 Mathieu Turcotte
```

#### loglevel — MIT

```
Copyright (c) 2013 Tim Perry
```

---

## Updating the bundled SDK

When upgrading the Twilio Voice JS SDK, update **all** of the following so they stay in sync:

1. `assets/twilio.min.js` (the single bundled copy, used by both web and macOS)
2. The **bundled version** recorded in this file
3. `CHANGELOG.md`

The Dart/Swift interop in this package is written against a specific Twilio Voice JS SDK version,
so replacing the asset with a different version may cause runtime failures.
