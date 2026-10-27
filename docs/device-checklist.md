# Device checklist

What the simulators couldn't show, collected from the "as built" sections of `docs/native-plan.md`. Tick each line on a real device; a failed line goes back into the plan with what you saw.

## Setup, once

1. Xcode → Settings → Accounts → **+** → Apple ID. A free Personal Team is enough. Its apps stop opening after 7 days: run the script again.
2. On the device: Settings → Privacy & Security → **Developer Mode** on (it restarts).
3. Connect it by cable (Vision Pro: Settings → General → Remote Devices, then pair from Xcode → Window → Devices and Simulators). Trust this Mac.
4. `tools/run-device.sh iphone` or `tools/run-device.sh vision`. The first run writes `apple/Local.xcconfig` with your team, registers the device and builds a Release app. If several devices are paired, add the device's name: `tools/run-device.sh iphone Release "Erich's iPhone"`.
5. First launch only: Settings → General → VPN & Device Management → your Apple ID → **Trust**, then open Sand Art.

The test hooks work on a device too: `xcrun devicectl device process launch --device "<name>" <bundle id> -flipEvery 5`. The script prints the bundle ID: device builds use `art.sand.<team>.SandArt`, since a Personal Team can't share an app ID. Frame times: Console.app → the device → filter `subsystem:art.sand.SandArt` (or `art.sand.SandArtVision`).

## iPhone (any)

- [ ] Tilting the phone moves the sand the way gravity would: tip it left, sand slides left; lay it flat, sand stops falling and rests on the back pane.
- [ ] Tap flips the frame; the hanging sand lands and the rest pours.
- [ ] The reflections in the glass turn as you tilt.
- [ ] Glitter flakes flash as you tilt the phone (lit by the studio light, not a clock); air pockets show a silvery edge.
- [ ] A sideways drag turns the whole toy with your finger; let go and it rocks back upright. Sand runs to the low side while it's turned.
- [ ] The hint shows on first launch and fades after the first tap.
- [ ] Palette picker, Tuning button, sliders and the sheet's dismissal respond to touch.
- [ ] Turning to landscape and back keeps the same sand (no reseed, no stretch).
- [ ] Frame time in Console stays near 16 ms (60 fps), and the phone doesn't get hot after five minutes.

## iPhone Duo

- [ ] Flat open: the hinge reads about 180° (Console's log line: `hinge …°`), and the tuning panel sits beside the picture, clear of the fold.
- [ ] Tent: the picture is on the upright half, the wooden base (palette, Flip, Tuning) on the flat half.
- [ ] **Tent gravity, both ways round:** stand it as a tent, then turn it so the other half is upright. Sand must fall towards the hinge both times. If it falls away from the hinge one way, `TentGravity.sensorHalf` in `apple/SandKit/Sources/SandKit/Fold.swift` is the wrong half.
- [ ] Folding and unfolding keeps the same sand; the picture refits without reseeding.
- [ ] Closed: the cover display shows the flat layout.

## Vision Pro

- [ ] The volume opens on a real surface at its true size (glass about 33 × 24 cm) and stays that size as you walk away.
- [ ] You see the room through the clear liquid; its tint looks like the web's.
- [ ] The panes are barely visible face-on and show a clear sheen at a shallow angle.
- [ ] Pinch and drag on the frame spins it about its axle; let go and it settles on the nearer side, carried by the swing.
- [ ] A pinch without moving flips it.
- [ ] Picking up the stand moves the whole toy, and tilting it moves the sand sideways. Pinching the frame doesn't also pick up the stand.
- [ ] The ornament's palette and Flip buttons work.
- [ ] Glitter flashes as your head moves (each eye on its own), and air-pocket rims catch the light after a few flips.
- [ ] The sand looks right in both a dim and a bright room.
- [ ] Frame times in Console, and whether the log reports texture waits (`replace` waited); no heat or memory warnings after five minutes.
