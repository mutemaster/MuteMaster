# Third-Party Notices

MuteMaster incorporates the following third-party open-source software. Their license notices are
reproduced below as required.

## With gratitude 🙏

MuteMaster stands on the shoulders of generous open-source work:

- **Sindre Sorhus** and the **KeyboardShortcuts** contributors — for the excellent, well-maintained
  global-shortcuts library that powers our hotkeys.
- **ExistentialAudio** and the **BlackHole** project — whose loopback virtual-audio-device design
  was the inspiration for how our driver carries audio. (No BlackHole code is used here; we're simply
  grateful for the trail they blazed.)
- **Apple's NullAudio** sample code — which shaped the structure of our AudioServerPlugIn driver.

Thank you. 💛

---

## KeyboardShortcuts

- Project: https://github.com/sindresorhus/KeyboardShortcuts
- Author: Sindre Sorhus
- License: MIT
- Used as: vendored Swift package (`Vendor/KeyboardShortcuts/`); linked into the app to provide
  user-configurable global keyboard shortcuts.

```
MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## Notes on inspiration (no code incorporated)

The Core Audio driver and the lock-free ring buffer are original implementations. They were
*informed by* the design of the following projects but contain none of their source code, so no
additional license obligations apply:

- **Apple "NullAudio" sample** (AudioServerPlugIn structure / zero-timestamp clock).
- **BlackHole** by ExistentialAudio (loopback-via-ring-buffer concept). BlackHole is GPL-3.0; because
  no BlackHole code is used, the GPL does not apply to MuteMaster.

Apple system frameworks (CoreAudio, AudioToolbox, AVFoundation, SwiftUI, ServiceManagement) are used
under the macOS SDK and require no notice here.

---

## Trademarks

MuteMaster is not affiliated with, endorsed by, or sponsored by Zoom Video Communications, Inc.,
Google LLC, Slack Technologies, or any other company. "Zoom", "Google Meet", "Slack", and other
product names are trademarks of their respective owners and are referenced only to describe
compatibility (nominative use).
