#!/bin/bash
#############################################################################
# ExecStartPre for kprogrammer.service: bring this rig up to date before the
# programmer starts.
#
#  1. Copy anything staged on the SD card into place.
#  2. Pull this repo (eeprom images, instructions, the shipped binary).
#  3. Make sure there is a programmer binary that actually RUNS on this box.
#
# Steps 2 and 3 are best effort.  A rig is often on a bench with no route out,
# and it still has to program boards there, so every network step is gated on a
# reachability probe and every failure below leaves what is already on disk
# alone and exits 0.  This script must never be the reason the programmer does
# not start.
#
# Step 3 exists because the `programmer` committed here is a single build, and
# the libraries it links change soname between the Debian releases the FPP
# majors are built on (libgpiodcxx.so.1 -> .so.2, libjsoncpp.so.25 -> .26).  A
# rig on a different FPP major than the committed binary was built for dies at
# exec with status 127 and an unreadable "cannot open shared object file".  So
# when the committed binary will not load, fetch the one CI published for this
# platform and FPP major and run that instead.
#############################################################################

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd /home/fpp/media/cape-eeproms

if [ -f /dev/mmcblk0p1 ]; then
    mount -t auto /dev/mmcblk0p1 /mnt
    cp -f /mnt/k* /home/fpp/media/cape-eeproms/
    if [ -f /home/fpp/media/cape-eeproms/kulp-programmer.tgz ]; then
        cd /home/fpp/media/cape-eeproms
        tar -xzf /home/fpp/media/cape-eeproms/kulp-programmer.tgz
        rm -f /home/fpp/media/cape-eeproms/kulp-programmer.tgz
    fi
    chown -R fpp:fpp /home/fpp/media/cape-eeproms/*
    chmod +x /home/fpp/media/cape-eeproms/programmer/programmer
    chmod +x /home/fpp/media/cape-eeproms/programmer/write_cape_eeprom
    chmod +x /home/fpp/media/cape-eeproms/programmer/*.sh
    umount /mnt
    cd /home/fpp/media/cape-eeproms
fi

REPO_URL="${KLPROG_REPO_URL:-https://github.com/KulpLights/cape-eeproms}"
FPPDIR="${FPPDIR:-/opt/fpp}"

# One cheap probe up front rather than letting git and curl each discover it the
# slow way.  Offline, the retry loop below would spend its ten attempts and the
# download its own retries, all to arrive where we already are: use what is on
# disk.  git's smart-http discovery endpoint is the same host and path the pull
# needs, so this tests what actually has to work.
if curl -sf --connect-timeout 5 --max-time 15 -o /dev/null \
        "${REPO_URL}/info/refs?service=git-upload-pack"; then
    ONLINE=1
else
    ONLINE=0
    echo "check_for_new: ${REPO_URL} is unreachable - using the eeproms and binaries already on disk"
fi


# The pull can update THIS FILE, and bash reads a script incrementally from a
# file offset rather than slurping it: rewrite the file under a running shell
# and the interpreter resumes at a byte offset that now lands mid-token, then
# quietly stops.  Everything below the pull silently does not happen, with no
# error anywhere.  So note what the script looked like before, and if the pull
# changed it, re-exec so the rest runs from the version we just fetched.
SELF="${BASH_SOURCE[0]:-$0}"
SELF_SUM_BEFORE="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"

if [ "$ONLINE" = "1" ]; then
    for i in {1..10}; do
        sudo -u fpp git -c http.sslVerify=false pull -f --rebase
        if [ $? -eq 0 ]; then
            break
        fi
        sleep 2
    done
fi

# KPROG_REEXECED bounds this to a single re-exec: a script that somehow differs
# from itself every run would otherwise loop here forever and the programmer
# would never start.
if [ -z "${KPROG_REEXECED:-}" ] \
   && [ "$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)" != "$SELF_SUM_BEFORE" ]; then
    echo "check_for_new: the pull updated this script; restarting it"
    export KPROG_REEXECED=1
    exec "$SELF" "$@"
fi


#############################################################################
# A binary that loads on this box.
#############################################################################
TARGET="${BASEDIR}/programmer.local"     # gitignored, so a pull cannot clobber it
MARKER="${BASEDIR}/.programmer-major"

# A binary "runs" if the dynamic loader can resolve everything it needs.  This
# is the exact condition that fails, so testing it directly avoids executing the
# programmer (which would grab the OLED and the i2c bus) just to find out.
# ldd's exit status matters as much as its output: a binary for the wrong
# architecture entirely reports "not a dynamic executable" and exits non-zero,
# with no "not found" line to grep for, so a pipeline into grep alone would call
# it loadable.
loads() {
    local out
    [ -x "$1" ] || return 1
    out="$(ldd "$1" 2>&1)" || return 1
    ! grep -q "not found" <<<"$out"
}

if loads "${BASEDIR}/programmer"; then
    # The committed binary is right for this OS - nothing to fetch, and an
    # override left over from a previous image would only mask it.
    rm -f "${TARGET}" "${MARKER}"
    exit 0
fi
echo "check_for_new: the committed programmer does not load on this FPP"

# `uname -m` is NOT reliable for the userspace bitness: a 64-bit kernel under a
# 32-bit FPP reports aarch64.  Read the ELF class of an FPP binary instead -
# byte 5 of the ELF header is 2 for 64-bit, 1 for 32-bit.
fpp_is_64bit() {
    local f=""
    for c in "${FPPDIR}/src/fppd" "${FPPDIR}/src/libfpp.so"; do
        [ -r "$c" ] && { f="$c"; break; }
    done
    if [ -n "$f" ]; then
        case "$(od -An -t u1 -j4 -N1 "$f" 2>/dev/null | tr -d '[:space:]')" in
            2) return 0 ;;
            1) return 1 ;;
        esac
    fi
    [ "$(getconf LONG_BIT 2>/dev/null)" = "64" ]
}
if fpp_is_64bit; then PLAT="BB64"; else PLAT="BBB"; fi

MAJ="$(grep -oE 'FPP_MAJOR_VERSION[[:space:]]+[0-9]+' "${FPPDIR}/src/fppversion_defines.h" 2>/dev/null | grep -oE '[0-9]+$')"
if [ -z "$MAJ" ]; then
    echo "check_for_new: cannot determine the FPP major version; leaving the binary alone" >&2
    exit 0
fi

if loads "$TARGET" && [ "$(cat "$MARKER" 2>/dev/null)" = "${PLAT}-${MAJ}" ]; then
    echo "check_for_new: ${PLAT} programmer for FPP ${MAJ} already installed"
    exit 0
fi

if [ "$ONLINE" != "1" ]; then
    # Nothing usable on disk and no way to fetch one.  Say so plainly: the
    # programmer is about to exit 127 and that message alone explains nothing.
    echo "check_for_new: no ${PLAT} programmer for FPP ${MAJ} on disk and no network to fetch one." >&2
    echo "check_for_new: connect this rig to the network once to install it." >&2
    exit 0
fi

ASSET="kl-programmer-oled-${PLAT}-${MAJ}.gz"
URL="${REPO_URL}/releases/download/fpp${MAJ}/${ASSET}"
SUMSURL="${REPO_URL}/releases/download/fpp${MAJ}/checksums.txt"

TMP="$(mktemp "${BASEDIR}/.programmer.XXXXXX.gz")"
SUMS="$(mktemp "${TMPDIR:-/tmp}/kprog.XXXXXX.sums")"
trap 'rm -f "$TMP" "${TMP%.gz}" "$SUMS"' EXIT

# Verify before the download can replace a working binary.  The binaries and
# checksums.txt are separate assets, so a fetch landing mid-publish can see a
# mismatched pair; one re-fetch of both resolves that.
VERIFY="pending"
for ATTEMPT in 1 2; do
    if ! curl -fSL --retry 3 --connect-timeout 10 --max-time 300 -o "$TMP" "$URL"; then
        echo "check_for_new: ERROR downloading ${URL}" >&2
        echo "check_for_new: no rig binary published for ${PLAT} on FPP ${MAJ}." >&2
        exit 0
    fi
    if ! curl -fsL --retry 3 --connect-timeout 10 --max-time 60 -o "$SUMS" "$SUMSURL"; then VERIFY="no-checksums"; break; fi
    EXPECTED="$(awk -v a="$ASSET" '$2 == a { print tolower($1); exit }' "$SUMS")"
    if [ -z "$EXPECTED" ]; then VERIFY="unlisted"; break; fi
    ACTUAL="$(sha256sum "$TMP" | cut -d' ' -f1)"
    if [ "$ACTUAL" = "$EXPECTED" ]; then VERIFY="ok"; break; fi
    VERIFY="mismatch"
    [ "$ATTEMPT" = "1" ] && echo "check_for_new: checksum mismatch, re-fetching ..." >&2
done
case "$VERIFY" in
    ok)           echo "check_for_new: checksum verified for ${ASSET}" ;;
    no-checksums) echo "check_for_new: release fpp${MAJ} has no checksums.txt, skipping verification" ;;
    unlisted)     echo "check_for_new: WARNING: ${ASSET} not listed in checksums.txt" >&2 ;;
    *)
        echo "check_for_new: ERROR: checksum mismatch for ${ASSET}; keeping what is installed." >&2
        exit 0
        ;;
esac

if ! gunzip -f "$TMP"; then
    echo "check_for_new: ERROR decompressing ${ASSET}" >&2
    exit 0
fi
# mktemp creates 0600 and mv preserves it; the programmer has to be executable.
chmod 755 "${TMP%.gz}"
mv -f "${TMP%.gz}" "$TARGET"
echo "${PLAT}-${MAJ}" > "$MARKER"
echo "check_for_new: installed the ${PLAT} programmer for FPP ${MAJ}"
exit 0
