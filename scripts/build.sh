#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=debug
IDENTITY="${SIGNING_IDENTITY:--}"
PROFILE="${PROVISIONING_PROFILE:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
DISTRIBUTE=false

usage() {
    cat <<'USAGE'
Usage: bash scripts/build.sh [debug|release] [options]

  --identity NAME       Signing identity (or SIGNING_IDENTITY; default: ad-hoc "-").
  --profile PATH        Optional macOS provisioning profile (or PROVISIONING_PROFILE).
                        Required only for optional Touch ID / Mac-password unlock.
  --distribute          Require release, Developer ID Application signing, secure
                        timestamp, notarization, stapling and Gatekeeper assessment.
  --notary-profile NAME notarytool keychain profile (or NOTARYTOOL_PROFILE).
                        Required with --distribute; never pass credentials here.
  --help, -h            Show this help.

Local password-only build:
  bash scripts/build.sh release

Optional provisioned local unlock (keep the profile outside the repository):
  bash scripts/build.sh debug --identity "Apple Development: Name (TEAMID)" \
    --profile /absolute/path/to/TinyStash.provisionprofile

Distribution (create the keychain profile separately with notarytool store-credentials):
  bash scripts/build.sh release --distribute \
    --identity "Developer ID Application: Name (TEAMID)" --notary-profile TinyStash
Add --profile with a matching Developer ID provisioning profile for local unlock.
Real-identity signing uses a secure timestamp and requires network access.
Quit Tiny Stash before replacing its bundle. Builds target the current architecture.
USAGE
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        debug|release)
            CONFIGURATION="$1"
            shift
            ;;
        --identity|--profile|--notary-profile)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                die "$1 requires a value."
            fi
            case "$1" in
                --identity) IDENTITY="$2" ;;
                --profile) PROFILE="$2" ;;
                --notary-profile) NOTARY_PROFILE="$2" ;;
            esac
            shift 2
            ;;
        --distribute)
            DISTRIBUTE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$IDENTITY" ]] || die 'The signing identity must not be empty.'
if [[ -n "$PROFILE" ]]; then
    [[ "$IDENTITY" != '-' ]] || die 'A provisioning profile requires a real Apple signing identity.'
    [[ -f "$PROFILE" ]] || die 'The provisioning profile is not a regular file.'
fi
if [[ "$DISTRIBUTE" == true ]]; then
    [[ "$CONFIGURATION" == release ]] || die '--distribute requires the release configuration.'
    [[ "$IDENTITY" != '-' ]] || die '--distribute requires a Developer ID Application identity.'
    [[ -n "$NOTARY_PROFILE" ]] || die '--distribute requires --notary-profile (or NOTARYTOOL_PROFILE).'
fi
[[ "$(uname -s)" == Darwin ]] || die 'Building the macOS application requires macOS.'
command -v swift >/dev/null || die 'Install Xcode with Swift 6 before building.'
if [[ "$DISTRIBUTE" == true ]]; then
    /usr/bin/xcrun --find notarytool >/dev/null
    /usr/bin/xcrun --find stapler >/dev/null
fi
/usr/bin/plutil -lint "$PROJECT_ROOT/Resources/Info.plist" "$PROJECT_ROOT/Resources/TinyStash.entitlements"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_ROOT/Resources/Info.plist")"

swift build --package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION" --product TinyStash
BIN_DIRECTORY="$(swift build --package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$PROJECT_ROOT/build"
PACKAGING_DIRECTORY="$(mktemp -d "$PROJECT_ROOT/build/packaging.XXXXXX")"
trap 'rm -rf "$PACKAGING_DIRECTORY"' EXIT
# Stage a fresh bundle: a failed signing/notarization never publishes a partial build
# or retains an earlier profile/signature. Existing successful outputs stay intact.
STAGED_APP="$PACKAGING_DIRECTORY/Tiny Stash.app"
CONTENTS="$STAGED_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIRECTORY/TinyStash" "$CONTENTS/MacOS/TinyStash"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_ROOT/Resources/TinyStash.icns" "$CONTENTS/Resources/TinyStash.icns"

if [[ "$IDENTITY" == '-' ]]; then
    /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$STAGED_APP"
else
    # Inspect the selected certificate rather than trusting its user-supplied name.
    /usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp "$STAGED_APP"
    SIGNATURE_DETAILS="$(/usr/bin/codesign --display --verbose=4 "$STAGED_APP" 2>&1)"
    TEAM_IDENTIFIER=''
    DEVELOPER_ID=false
    while IFS= read -r LINE; do
        case "$LINE" in
            TeamIdentifier=*) TEAM_IDENTIFIER="${LINE#TeamIdentifier=}" ;;
            'Authority=Developer ID Application:'*) DEVELOPER_ID=true ;;
        esac
    done <<< "$SIGNATURE_DETAILS"
    if [[ "$DISTRIBUTE" == true && "$DEVELOPER_ID" != true ]]; then
        die '--distribute requires a Developer ID Application certificate, not a development or ad-hoc identity.'
    fi

    if [[ -n "$PROFILE" ]]; then
        PROFILE_PLIST="$PACKAGING_DIRECTORY/profile.plist"
        /usr/bin/security cms -D -i "$PROFILE" -o "$PROFILE_PLIST"
        PROFILE_PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$PROFILE_PLIST")"
        [[ "$PROFILE_PLATFORM" == OSX || "$PROFILE_PLATFORM" == macOS ]] ||
            die 'The provisioning profile must authorize macOS.'
        PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST")"
        PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
        if [[ ! "$TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ || "$TEAM_IDENTIFIER" != "$PROFILE_TEAM" ]]; then
            die 'Signing certificate and provisioning profile must identify the same Apple Developer team.'
        fi
        APP_IDENTIFIER="$TEAM_IDENTIFIER.$BUNDLE_IDENTIFIER"
        # Apple provisioning profiles may authorize an exact app ID or a wildcard.
        [[ "$APP_IDENTIFIER" == $PROFILE_APP_IDENTIFIER ]] ||
            die "The provisioning profile does not authorize $APP_IDENTIFIER."

        # Preserve the stable private Keychain group; do not add sharing/debug entitlements.
        ENTITLEMENTS="$PACKAGING_DIRECTORY/TinyStash.entitlements"
        cp "$PROJECT_ROOT/Resources/TinyStash.entitlements" "$ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier $APP_IDENTIFIER" "$ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $TEAM_IDENTIFIER" "$ENTITLEMENTS"
        cp "$PROFILE" "$CONTENTS/embedded.provisionprofile"
        /usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp \
            --generate-entitlement-der --entitlements "$ENTITLEMENTS" "$STAGED_APP"
    fi
fi
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"

if [[ "$DISTRIBUTE" == true ]]; then
    SUBMISSION_ZIP="$PACKAGING_DIRECTORY/submission.zip"
    /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$SUBMISSION_ZIP"
    # Authentication lives in the user's Keychain, never in this repository.
    NOTARY_RESULT="$PACKAGING_DIRECTORY/notary-result.plist"
    if ! /usr/bin/xcrun notarytool submit "$SUBMISSION_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$NOTARY_RESULT"; then
        # Preserve the submission ID/status in terminal output even on a failed wait.
        if [[ -s "$NOTARY_RESULT" ]]; then
            cat "$NOTARY_RESULT" >&2
        fi
        die 'Notarytool failed. Inspect the error above; use notarytool log with the submission ID if one was returned.'
    fi
    NOTARY_STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$NOTARY_RESULT")"
    if [[ "$NOTARY_STATUS" != Accepted ]]; then
        /usr/bin/plutil -p "$NOTARY_RESULT" >&2
        die 'Notarization was not accepted. Retrieve the submission log with notarytool log using the submission ID above.'
    fi
    /usr/bin/xcrun stapler staple "$STAGED_APP"
    /usr/bin/xcrun stapler validate "$STAGED_APP"
    /usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP"
    # Archive only after stapling, so recipients can validate the ticket offline.
    /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$PACKAGING_DIRECTORY/Tiny Stash-notarized.zip"
fi

APP_PATH="$PROJECT_ROOT/build/Tiny Stash.app"
rm -rf "$APP_PATH"
mv "$STAGED_APP" "$APP_PATH"
if [[ "$DISTRIBUTE" == true ]]; then
    ARCHIVE_PATH="$PROJECT_ROOT/build/Tiny Stash-notarized.zip"
    mv -f "$PACKAGING_DIRECTORY/Tiny Stash-notarized.zip" "$ARCHIVE_PATH"
    printf 'Built and verified notarized distribution: %s\nApp: %s\n' "$ARCHIVE_PATH" "$APP_PATH"
else
    printf 'Built and signature-verified %s (%s). Not a notarized distribution release.\n' "$APP_PATH" "$CONFIGURATION"
fi
if [[ -n "$PROFILE" ]]; then
    printf 'Provisioned for %s; verify authenticated Keychain unlock interactively on the target Mac.\n' "$APP_IDENTIFIER"
else
    printf '%s\n' 'Password-only build. Optional Touch ID / Mac-password unlock requires a matching identity and provisioning profile.'
fi
