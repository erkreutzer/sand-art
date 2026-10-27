#!/bin/sh
# Builds, installs and launches an app on a real iPhone or Vision Pro: the core
# (tools/build-apple.sh), the Xcode project (XcodeGen), a signed device build,
# then devicectl. Prints only errors and what it did.
#   tools/run-device.sh iphone|vision [Release|Debug] [device name]
# Needs: an Apple ID in Xcode → Settings → Accounts (a free Personal Team is
# fine); the device paired with this Mac and Developer Mode on (Settings →
# Privacy & Security). Free-team apps stop opening after 7 days: run it again.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$1" in
  iphone) scheme=SandArt; platform=iOS; sdk=iphoneos ;;
  vision) scheme=SandArtVision; platform=visionOS; sdk=xros ;;
  *) echo "usage: tools/run-device.sh iphone|vision [Release|Debug] [device name]" >&2; exit 2 ;;
esac
config="${2:-Release}"
want="$3"
local_cfg="$root/apple/Local.xcconfig"

# The team: Local.xcconfig, else the one team of the Apple ID signed in to Xcode,
# else (Xcode 27 no longer lists teams in its defaults) the team (OU) of the
# Apple Development certificates in the keychain.
if ! grep -qE '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' "$local_cfg" 2>/dev/null; then
  teams=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -oE 'teamID = "?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' | sort -u)
  if [ -z "$teams" ]; then
    teams=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
      | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{printf "%s", c | "openssl x509 -noout -subject -nameopt multiline"; close("openssl x509 -noout -subject -nameopt multiline")}' \
      | grep -E 'organizationalUnitName' | grep -oE '[A-Z0-9]{10}$' | sort -u)
  fi
  n=$(printf '%s' "$teams" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    echo "No signing team. In Xcode → Settings → Accounts, select your Apple ID, then Manage Certificates… → + → Apple Development, and run this again (or put the team in apple/Local.xcconfig)." >&2
    exit 1
  elif [ "$n" -gt 1 ]; then
    echo "Several teams ($(echo $teams)): put one in apple/Local.xcconfig (see Local.xcconfig.example)." >&2
    exit 1
  fi
  lower=$(printf '%s' "$teams" | tr 'A-Z' 'a-z')
  cat > "$local_cfg" <<EOF
// Written by tools/run-device.sh (not committed). See Local.xcconfig.example.
DEVELOPMENT_TEAM = $teams
SAND_BUNDLE_PREFIX[sdk=iphoneos*] = art.sand.$lower
SAND_BUNDLE_PREFIX[sdk=xros*] = art.sand.$lower
EOF
  echo "Signing with team $teams (apple/Local.xcconfig)."
fi

# The device: a paired, connected one of this platform (not a simulator).
json=$(mktemp -t sand-devices)
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
pick=$(python3 -I - "$json" "$platform" "$want" <<'EOF'
import json, sys
path, platform, want = sys.argv[1], sys.argv[2], sys.argv[3]
devs = []
for d in json.load(open(path)).get("result", {}).get("devices", []):
    h, c, p = d["hardwareProperties"], d["connectionProperties"], d["deviceProperties"]
    if h.get("platform") != platform or c.get("transportType") in (None, "sameMachine"):
        continue
    if c.get("pairingState") != "paired" or (want and p.get("name") != want):
        continue
    devs.append((c.get("tunnelState") == "connected", d["identifier"], h.get("udid", ""), p.get("name", "")))
devs.sort(reverse=True)
if devs:
    print("\t".join(devs[0][1:]))
EOF
)
rm -f "$json"
if [ -z "$pick" ]; then
  echo "No paired $platform device${want:+ named \"$want\"}. Connect it, trust this Mac, and pair it in Xcode → Window → Devices and Simulators." >&2
  exit 1
fi
device=$(printf '%s' "$pick" | cut -f1)
udid=$(printf '%s' "$pick" | cut -f2)
name=$(printf '%s' "$pick" | cut -f3)

"$root/tools/build-apple.sh"
cd "$root/apple"
if ! log=$(xcodegen --quiet 2>&1); then printf '%s\n' "$log"; exit 1; fi
derived="$root/apple/build/DerivedData"
# A Personal Team can only make a profile for a registered device, so build for
# this one (Xcode registers it) rather than a generic destination.
if ! log=$(xcodebuild -project SandArt.xcodeproj -scheme "$scheme" -configuration "$config" \
    -destination "id=$udid" -derivedDataPath "$derived" -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration -quiet build 2>&1); then
  printf '%s\n' "$log" | grep -E 'error|failed' || printf '%s\n' "$log" | tail -30
  exit 1
fi
app="$derived/Build/Products/$config-$sdk/$scheme.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
xcrun devicectl device install app --device "$device" "$app" --quiet
echo "Installed $bundle on $name."
if ! xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" --quiet 2>/dev/null; then
  echo "Couldn't launch it. The first time, trust the developer on the device: Settings → General → VPN & Device Management → your Apple ID → Trust. Then open Sand Art." >&2
  exit 1
fi
echo "Launched."
