# Third-party notices

This project redistributes or depends on the following third-party work.

## Meta Wearables Device Access Toolkit

`ios-app/` is built on the `CameraAccess` sample from
<https://github.com/facebook/meta-wearables-dat-ios> (version 1.0.1), which the
app also links as a Swift package dependency. Meta's own `LICENSE` and `NOTICE`
files are kept at the root of this repository and cover that code. Use of the
toolkit is subject to the Meta Wearables Developer Terms
(<https://wearables.developer.meta.com/terms>).

## MediaPipe (Google)

Hand tracking uses MediaPipe Tasks Vision 1.2.3, licensed under the Apache
License 2.0. A copy of that licence is in `LICENSE-APACHE-2.0`.

Two parts of MediaPipe are involved:

- The `MediaPipeTasksVision`, `MediaPipeTasksCommon` and `MediaPipeTaskGraphs`
  xcframeworks, declared in `ios-app/MediaPipeLocal/Package.swift` and downloaded
  from Google at build time. They are not stored in this repository.
- **`ios-app/CameraAccess/hand_landmarker.task`**, the Hand Landmarker model
  bundle, which *is* stored in this repository. It is Google's work, released
  under the Apache License 2.0; see
  <https://developers.google.com/mediapipe/solutions/vision/hand_landmarker>.

Neither Google nor MediaPipe endorses this project.

## Gemini API (Google)

Scene understanding calls the Gemini API over HTTPS. No Google code is bundled
for this; the API is used under Google's own terms
(<https://ai.google.dev/gemini-api/terms>). An API key is not included in this
repository and has to be supplied by whoever runs the app.

## Arduino

`arduino-app/` is written for Arduino App Lab and uses the `Arduino_RouterBridge`
and `Arduino_LED_Matrix` libraries, which App Lab supplies on the board. They are
not vendored here.
