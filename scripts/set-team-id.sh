#!/usr/bin/env bash
#
# Points every signing reference in Airway at your own Apple Developer Team ID.
#
#   scripts/set-team-id.sh YOURTEAMID
#
# Airway's privileged fan helper only talks to an app signed by the same team,
# and the app only installs a helper signed by that team. Both checks name the
# Team ID, so a build signed by your Apple ID needs your Team ID in all of:
#
#   Airway.xcodeproj/project.pbxproj        DEVELOPMENT_TEAM for every target
#   Airway.app/Info.plist                   SMPrivilegedExecutables requirement
#   com.airway.helper/Info.plist            SMAuthorizedClients requirement
#   com.airway.helper/HelperService.swift   the helper's XPC client check
#
# Find your Team ID after signing in to Xcode once:
#
#   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
#
# It is the 10-character value after OU=.

set -euo pipefail

NEW_TEAM="${1:-}"
if ! [[ "$NEW_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Usage: $0 YOURTEAMID" >&2
  echo "A Team ID is 10 capital letters and digits, like ABCDE12345." >&2
  echo 'Find yours with: security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject' >&2
  exit 1
fi

cd "$(dirname "$0")/.."

FILES=(
  Airway.xcodeproj/project.pbxproj
  Airway.app/Info.plist
  com.airway.helper/Info.plist
  com.airway.helper/HelperService.swift
)

# The Team ID currently in the project, so this also works a second time.
OLD_TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]\{10\}\);.*/\1/p' Airway.xcodeproj/project.pbxproj | head -n 1)"
if [ -z "$OLD_TEAM" ]; then
  echo "error: could not find DEVELOPMENT_TEAM in Airway.xcodeproj/project.pbxproj" >&2
  exit 1
fi
if [ "$OLD_TEAM" = "$NEW_TEAM" ]; then
  echo "Already using Team ID $NEW_TEAM."
  exit 0
fi

perl -pi -e "s/\Q$OLD_TEAM\E/$NEW_TEAM/g" "${FILES[@]}"

for file in "${FILES[@]}"; do
  if grep -q "$OLD_TEAM" "$file"; then
    echo "error: $file still mentions $OLD_TEAM" >&2
    exit 1
  fi
done

echo "Switched Team ID from $OLD_TEAM to $NEW_TEAM in:"
printf '  %s\n' "${FILES[@]}"
