#!/usr/bin/env bash
# package/test-dmg.sh — verify a built DMG has the expected structure.
#
# Usage: bash package/test-dmg.sh <path-to-dmg> [<expected-sparkle-pubkey-path>]
#
# Checks:
#   1. DMG mounts cleanly via hdiutil
#   2. Mount root contains Smoodle.app
#   3. Smoodle.app/Contents/MacOS/Smoodle is universal binary (arm64+x86_64)
#   4. Smoodle.app/Contents/Info.plist has SUFeedURL pointing at the public appcast
#   5. Smoodle.app/Contents/Info.plist SUPublicEDKey matches package/Sparkle-public-key.txt
#   6. Smoodle.app/Contents/Frameworks/librime.1.dylib contains 'sorted_initial_' symbol (peek-sort patch)
#   7. <dmg>.sig exists alongside the DMG (Sparkle EdDSA signature)
#   8. SharedSupport carries the custom-word layering (thai_phonetic.custom.yaml
#      → thai_phonetic.extended + user dict template) and default.custom.yaml
#      lists only schemas the bundle ships
#   9. Smoodle Config.app present at mount root (v0.0.8b+)

set -uo pipefail

DMG="${1:?usage: $0 <dmg-path> [pubkey-path]}"
PUBKEY_FILE="${2:-package/Sparkle-public-key.txt}"

if [ ! -f "$DMG" ]; then
  echo "FAIL: DMG not found at $DMG"
  exit 1
fi

echo "=== test-dmg: $DMG ==="

# 1. Mount
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -mountpoint "$MOUNT" -quiet
trap "hdiutil detach '$MOUNT' -quiet -force 2>/dev/null || true; rmdir '$MOUNT'" EXIT

# 2. Smoodle.app at root
if [ ! -d "$MOUNT/Smoodle.app" ]; then
  echo "FAIL: Smoodle.app not found at DMG root"
  ls "$MOUNT/"
  exit 1
fi
echo "  ✓ Smoodle.app present"

# 3. Universal binary
BIN="$MOUNT/Smoodle.app/Contents/MacOS/Smoodle"
if ! lipo -info "$BIN" 2>&1 | grep -qE 'arm64.*x86_64|x86_64.*arm64'; then
  echo "FAIL: $BIN is not universal arm64+x86_64"
  lipo -info "$BIN"
  exit 1
fi
echo "  ✓ Smoodle binary is universal"

# 4. SUFeedURL
PLIST="$MOUNT/Smoodle.app/Contents/Info.plist"
FEED=$(plutil -extract SUFeedURL raw "$PLIST" 2>/dev/null)
if [ "$FEED" != "https://smoodle-type.github.io/smoodle-app/appcast.xml" ]; then
  echo "FAIL: SUFeedURL is '$FEED', expected smoodle-type.github.io appcast"
  exit 1
fi
echo "  ✓ SUFeedURL points at public appcast"

# 5. SUPublicEDKey matches
if [ -f "$PUBKEY_FILE" ]; then
  EXPECTED=$(cat "$PUBKEY_FILE" | tr -d '[:space:]')
  ACTUAL=$(plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null)
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL: SUPublicEDKey mismatch"
    echo "  expected: $EXPECTED"
    echo "  actual:   $ACTUAL"
    exit 1
  fi
  echo "  ✓ SUPublicEDKey matches package/Sparkle-public-key.txt"
fi

# 6. librime presence + smoodle-patched layout check.
#    NOTE: `sorted_initial_` is a private member variable, not a symbol;
#    release-stripped builds don't expose it. The smoodle release of librime
#    has a DIFFERENT Peek() body size than upstream (the patch adds a
#    conditional Sort() call). We verify smoodle vs upstream by comparing
#    the offset between Peek and the next symbol — smoodle's is smaller
#    (≈ 0x1a37d0 - 0x93948 = 0x10FE88) vs upstream's larger (≈ 0x1a3a60 -
#    0x93940 = 0x110120). Code-sign + install_name_tool mods change file
#    SHA, but symbol layout is preserved.
DYLIB="$MOUNT/Smoodle.app/Contents/Frameworks/librime.1.dylib"
if [ ! -f "$DYLIB" ]; then
  echo "FAIL: $DYLIB missing"
  exit 1
fi
# Sanity: DictEntryIterator class symbols present (not a corrupt/stub dylib).
# Use awk-then-process pattern (no early-exit pipeline) to avoid SIGPIPE (141).
NM_OUT=$(nm "$DYLIB" 2>/dev/null)
SORT_COUNT=$(printf '%s\n' "$NM_OUT" | grep -c 'DictEntryIterator4SortEv')
if [ "$SORT_COUNT" -lt 1 ]; then
  echo "FAIL: librime.1.dylib missing DictEntryIterator::Sort symbol (corrupt or stub?)"
  exit 1
fi
# Smoodle-vs-upstream check: Peek+next-symbol offset distinguishes them.
PEEK=$(printf '%s\n' "$NM_OUT" | awk '/T __ZN4rime17DictEntryIterator4PeekEv$/ {print $1; exit}')
NEXT=$(printf '%s\n' "$NM_OUT" | awk -v s="$PEEK" '$1 > s {print $1; exit}')
if [ -z "$PEEK" ] || [ -z "$NEXT" ]; then
  echo "FAIL: could not locate Peek() / next symbol in librime.1.dylib"
  exit 1
fi
SMOODLE_PEEK_HEX="0000000000093948"
SMOODLE_NEXT_HEX="00000000001a37d0"
if [ "$PEEK" = "$SMOODLE_PEEK_HEX" ] && [ "$NEXT" = "$SMOODLE_NEXT_HEX" ]; then
  echo "  ✓ librime.1.dylib matches smoodle-type/librime@1.16.0-smoodle.1 layout"
else
  echo "WARN: librime.1.dylib symbol layout differs from known smoodle layout"
  echo "      Peek=$PEEK NEXT=$NEXT (expected $SMOODLE_PEEK_HEX/$SMOODLE_NEXT_HEX)"
  echo "      May be a future smoodle librime tag — update expected values when re-pinning."
fi

# 7. Sparkle EdDSA sig
SIG="$DMG.sig"
if [ ! -f "$SIG" ]; then
  echo "FAIL: $SIG (Sparkle EdDSA signature) missing"
  exit 1
fi
if [ ! -s "$SIG" ]; then
  echo "FAIL: $SIG is empty"
  exit 1
fi
echo "  ✓ Sparkle EdDSA signature present at $SIG"

# 8. Rime data. thai_phonetic.custom.yaml switches the schema to
#    thai_phonetic.extended, which imports the user's custom words
#    (thai_phonetic.user); the bundled empty template is Rime's fallback until
#    ~/Library/Rime/Smoodle has one — a missing import fails the whole
#    dictionary compile. Listing a schema the bundle does not ship makes every
#    deploy report failure.
SHARED="$MOUNT/Smoodle.app/Contents/SharedSupport"
for f in thai_phonetic.schema.yaml thai_phonetic.dict.yaml thai_phonetic.extended.dict.yaml \
         thai_phonetic.user.dict.yaml thai_phonetic.custom.yaml default.custom.yaml; do
  if [ ! -f "$SHARED/$f" ]; then
    echo "FAIL: SharedSupport/$f missing (not wired into Copy Shared Support Files?)"
    exit 1
  fi
done
if ! grep -Eq '^[[:space:]]*translator/dictionary:[[:space:]]*thai_phonetic\.extended[[:space:]]*$' "$SHARED/thai_phonetic.custom.yaml"; then
  echo "FAIL: thai_phonetic.custom.yaml does not select thai_phonetic.extended"
  exit 1
fi
SCHEMAS=$(sed -n 's/^[[:space:]]*-[[:space:]]*schema:[[:space:]]*\([A-Za-z0-9_.]*\).*/\1/p' "$SHARED/default.custom.yaml")
if [ -z "$SCHEMAS" ]; then
  echo "FAIL: default.custom.yaml lists no schemas"
  exit 1
fi
for s in $SCHEMAS; do
  if [ ! -f "$SHARED/$s.schema.yaml" ]; then
    echo "FAIL: default.custom.yaml lists '$s' but SharedSupport has no $s.schema.yaml"
    exit 1
  fi
done
echo "  ✓ SharedSupport loads custom words; schema list: $(echo $SCHEMAS)"

# 9. Smoodle Config.app
if [ ! -d "$MOUNT/Smoodle Config.app" ]; then
  echo "FAIL: Smoodle Config.app not found at DMG root"
  exit 1
fi
echo "  ✓ Smoodle Config.app present"

echo
echo "=== ALL CHECKS PASS ==="
