app := "Cochlea"
destination := env("IOS_TEST_DESTINATION", "platform=iOS Simulator,name=iPhone 17")
derived := env("IOS_DERIVED_DATA", env("HOME") + "/Library/Developer/Xcode/DerivedData/cochlea")

gen:
    "$(realpath "$(command -v xcodegen)")" generate

dev: gen
    open {{app}}.xcodeproj

test: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{app}} -derivedDataPath "{{derived}}" -destination "{{destination}}" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES -parallel-testing-enabled NO test

check: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{app}} -derivedDataPath "{{derived}}" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build

build: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{app}} -derivedDataPath "{{derived}}" -destination "generic/platform=iOS" -configuration Debug -allowProvisioningUpdates DEVELOPMENT_TEAM="${IOS_TEAM_ID:?Set IOS_TEAM_ID}" build

deploy: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{app}} -derivedDataPath "{{derived}}" -destination "generic/platform=iOS" -configuration Release DEVELOPMENT_TEAM="${IOS_TEAM_ID:?Set IOS_TEAM_ID}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" IOS_APP_PROFILE="${IOS_PROFILE:?Set IOS_PROFILE}" IOS_ACTIVITY_PROFILE="${IOS_ACTIVITY_PROFILE:?Set IOS_ACTIVITY_PROFILE}" build
    xcrun devicectl device install app --device "${IOS_DEVICE_ID:?Set IOS_DEVICE_ID}" "{{derived}}/Build/Products/Release-iphoneos/{{app}}.app"

# Serve a decrypted IPA after verifying both bundles for IOS_TEAM_ID / IOS_DEVICE_ID.
ota ipa="build/Cochlea.ipa":
    python3 scripts/sign-ios.py --verify-ipa "{{ipa}}"
    bash scripts/ota-install.sh "{{ipa}}"

# --- project-specific ---
mac := "CochleaMac"
mac_derived := env("MAC_DERIVED_DATA", env("HOME") + "/Library/Developer/Xcode/DerivedData/cochlea-mac")

# unsigned macOS build - the CI gate for the Mac app
check-mac: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{mac}} -derivedDataPath "{{mac_derived}}" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build

# macOS unit tests (real ShazamKit custom catalog, Keychain, URLSession)
test-mac: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{mac}} -derivedDataPath "{{mac_derived}}" -destination "platform=macOS" CODE_SIGN_IDENTITY=- test

# unsigned Release build of the Mac app into build/ (CI signs, notarizes and publishes it)
build-mac: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{mac}} -derivedDataPath build/DerivedData -destination "platform=macOS" -configuration Release CODE_SIGNING_ALLOWED=NO build
    rm -rf "build/{{app}}.app"
    ditto "build/DerivedData/Build/Products/Release/{{app}}.app" "build/{{app}}.app"

# development-signed Release build of the Mac app for a local smoke test (microphone + Shazam need a signed bundle)
run-mac: gen
    xcodebuild -quiet -project {{app}}.xcodeproj -scheme {{mac}} -derivedDataPath "{{mac_derived}}" -destination "platform=macOS" -configuration Release -allowProvisioningUpdates build
    open "{{mac_derived}}/Build/Products/Release/{{app}}.app"
