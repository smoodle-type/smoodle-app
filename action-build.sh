#!/usr/bin/env bash

set -e

target="${1:-release}"

# export BUILD_UNIVERSAL=1

# v0.0.8a: regenerate smoodle schema from vendor/smoodle/ submodule into data/plum/.
# Must run BEFORE `make ${target}` because package/add_data_files (invoked by the
# release target) bundles data/plum/*.yaml into Smoodle.app's
# "Copy Shared Support Files" build phase. data/plum/ is gitignored in full —
# drift impossible by construction.
#
# v0.0.8b.3: Smoodle.app-only Rime data lives in data/smoodle/ (tracked, wired
# in place in project.pbxproj): default.custom.yaml (schema list = the one
# schema we ship), thai_phonetic.custom.yaml + thai_phonetic.extended.dict.yaml
# (load the user's custom words) and the empty thai_phonetic.user.dict.yaml
# fallback. vendor/smoodle/schema/default.custom.yaml is for the legacy
# Squirrel/Weasel/ibus installers and is not bundled.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_SRC="${SCRIPT_DIR}/vendor/smoodle/schema"

git submodule update --init vendor/smoodle

if [ ! -d "${SCHEMA_SRC}" ]; then
    echo "ERROR: ${SCHEMA_SRC} missing after submodule init" >&2
    exit 1
fi

echo "Copying schema from vendor/smoodle@$(cd "${SCHEMA_SRC}/.." && git describe --tags --always) → data/plum/"
mkdir -p data/plum
cp "${SCHEMA_SRC}/thai_phonetic.schema.yaml" data/plum/
cp "${SCHEMA_SRC}/thai_phonetic.dict.yaml" data/plum/
rm -f data/plum/default.custom.yaml  # stale copy from pre-0.0.8b.3 builds
echo "  schema copy: OK"

# preinstall
./action-install.sh

# build dependencies
# make deps

# build Squirrel
make "${target}"

echo 'Installer package:'
find package -type f -name '*.pkg' -or -name '*.zip'
