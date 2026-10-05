# Canonical secrets manifest - 1Password secret references only, SAFE to commit.
# Release secrets (Developer ID signing, notarization, cask push) live in the
# SHARED "Apple Signing" vault - not the project vault. CI resolves them via
# 1password/load-secrets-action with this repo's OP_SERVICE_ACCOUNT_TOKEN
# (the project's -ci service account is granted read on BOTH vaults).
# Refs are BY NAME on purpose: op-project-bootstrap parses this file.
DEVELOPER_ID_P12_BASE64=op://Apple Signing/Developer ID Application Cert/p12_base64
DEVELOPER_ID_P12_PASSWORD=op://Apple Signing/Developer ID Application Cert/password
ASC_KEY_P8_BASE64=op://Apple Signing/App Store Connect API Key/p8_base64
ASC_KEY_ID=op://Apple Signing/App Store Connect API Key/key_id
ASC_ISSUER_ID=op://Apple Signing/App Store Connect API Key/issuer_id
TAP_PUSH_TOKEN=op://Apple Signing/Homebrew Tap Push Token/token

# Project vault - the Mac client's own device credential, minted by Music Sync's
# capture-access endpoint and entered in the app's Settings (Keychain). Not read
# by CI; listed so op-project-bootstrap can derive the project vault.
COCHLEA_MAC_CAPTURE_TOKEN=op://Cochlea/Cochlea Music Sync Mac Capture Token/credential
