#!/bin/zsh
# Fails when a built app holds the code of encrypted sync (encryption outside the OS, see "Encrypted
# sync" in the README) or stops declaring ITSAppUsesNonExemptEncryption as false. Looks at every
# binary of the bundle: the app, its extensions, and the debug dylib of debug builds.
#
#   scripts/check-no-sync.sh path/to/Pressay.app
#   PRESSAY_SYNC_ENABLED=1 scripts/check-no-sync.sh ...   once the compliance key is in place
set -u

app=${1:?usage: check-no-sync.sh path/to/Pressay.app}
[[ -d $app ]] || { print -u2 "error: $app is not an app bundle"; exit 2; }

if [[ ${PRESSAY_SYNC_ENABLED:-0} == 1 ]]; then
  print "sync enabled: nothing to check"
  exit 0
fi

# Names of the Swift module and its types, and the magics of its envelopes: these survive stripping.
patterns='PressaySync|hChaCha20|HChaCha20|XChaCha20Poly1305|SyncCrypto|SyncService|PRSYSK01|PRSYSY01|PRSYRC01|/v1/sync/'
failed=0
scanned=0

for file in ${(f)"$(find "$app" -type f)"}; do
  file -b "$file" | grep -q 'Mach-O' || continue
  scanned=$((scanned + 1))
  name=${file#$app/}
  found=$({ strings -a "$file"; nm -a "$file" 2>/dev/null; } | grep -oE "$patterns" | sort -u | tr '\n' ' ')
  if [[ -n $found ]]; then
    print -u2 "error: $name holds sync code: $found"
    failed=1
  else
    print "ok: $name"
  fi
done

if (( scanned == 0 )); then
  print -u2 "error: no binary found in $app"
  failed=1
fi

declared=$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$app/Info.plist" 2>/dev/null)
if [[ $declared == false ]]; then
  print "ok: ITSAppUsesNonExemptEncryption is false"
else
  print -u2 "error: ITSAppUsesNonExemptEncryption is '${declared:-missing}', expected false while sync is off"
  failed=1
fi

exit $failed
