# HANDi

Smart glasses that let you control the room by looking at it.

Built at Junction 2026 for the Meta AI Glasses challenge.

## What it does

The glasses' first-person camera does two jobs at once.

**It knows what you are looking at.** Gemini checks one frame every 2 seconds and
tells the app whether the smart-home setup is in front of you. The hand controls
only work while it is, and an eye drawn on the Arduino's LED matrix opens when
they are armed and closes when they are not, so anyone in the room can see when
the glasses are acting.

**It knows what you are doing.** The same request classifies the scene (studying,
on the phone, walking away, cooking, eating...). The room then reacts on its own:
entering study mode dims lamp 1 to 75 %, walking away switches everything off, and
picking up the phone gets you a spoken nudge through the glasses' speakers.

## Gestures

Hand tracking runs on the phone with MediaPipe. A hand in the left half of the
glasses' view is the left hand, a hand in the right half is the right hand.

| Gesture | Action |
|---|---|
| Left hand, 1 finger | Select lamp 1 |
| Left hand, 2 fingers | Select lamp 2 |
| Right hand open, held | +20 % every 2 s |
| Right hand fist, held | -20 % every 2 s |
| Clap | Both lamps off |

The phone screen shows only the detected scenario and the gesture instructions:
the real feedback is the room itself and the voice in the glasses.

## Privacy

Frames are resized to 768 px, sent over HTTPS to the Gemini API and discarded.
Nothing is written to disk and nothing reaches the photo library. Only the
scenario and what is in view are kept, in memory.

## Repository layout

```
ios-app/        iPhone app (Swift / SwiftUI), built on Meta's CameraAccess sample
arduino-app/    Arduino UNO Q app (App Lab): sketch + Python + test web page
gemini-test/    Script used to compare Gemini models on sample frames
```

## Hardware

- Meta Ray-Ban glasses and an iPhone (iOS 17.2 or later)
- Arduino UNO Q
- Two LEDs with resistors on a breadboard: lamp 1 on pin D9, lamp 2 on pin D5
  (both PWM), short legs to GND
- The UNO Q's built-in 8x13 LED matrix, used for the eye

## Running it

### Arduino

1. Open Arduino App Lab, create an app and add the **Web UI - HTML** brick.
2. Copy `arduino-app/sketch/sketch.ino`, `arduino-app/python/main.py` and
   `arduino-app/assets/index.html` into it, each inside its own folder, then
   press Run.
3. Open `http://<board-ip>:7000` to check the lamps and the eye by hand before
   involving the glasses.

### iPhone

1. Open `ios-app/CameraAccess.xcodeproj` in Xcode and set your own signing team.
2. Enable Developer Mode for your glasses in the Meta AI app
   (Settings > Your glasses > Developer Mode). It has to be done per device.
3. Build, run, start the stream, then tap the badge to enter the Arduino's IP and
   your own Gemini API key. Both are stored on that phone only.

The phone and the board have to be on the same network. A phone hotspot works
well when the venue's Wi-Fi isolates clients from each other.

## Known limits

- Gemini answers in about a second, so the room reacts a couple of seconds after
  you do.
- Hand tracking depends on the glasses' video, which arrives over Bluetooth at
  360x640. Keep each hand on its own side of the view.
- The scenario only changes after two agreeing answers, which keeps a glance from
  flipping it but adds a short delay.

## Credits and licence

This project stands on other people's work:

- The iOS app is built on the `CameraAccess` sample from
  [meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios),
  which it also links as a dependency. Meta's `LICENSE` and `NOTICE` are kept at
  the root of this repository.
- Hand tracking uses **Google's MediaPipe** Tasks Vision (Apache 2.0). The Hand
  Landmarker model, `ios-app/CameraAccess/hand_landmarker.task`, is Google's and
  is redistributed here under that licence, a copy of which is in
  `LICENSE-APACHE-2.0`.
- Scene understanding calls the **Gemini API**. No key is included here.
- The Arduino app uses `Arduino_RouterBridge` and `Arduino_LED_Matrix`, supplied
  by Arduino App Lab on the board.

`THIRD-PARTY-NOTICES.md` spells out each of these, including which parts are
stored in this repository and which are downloaded at build time.
