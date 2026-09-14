#!/bin/bash
#############################################################################
# ExecStartPre for kprogrammer.service: bring this rig up to date before the
# programmer starts.
#
#  1. Copy anything staged on the SD card into place.
#  2. Pull this repo (eeprom images, instructions).
#  3. Install the programmer binary CI published for this platform and FPP
#     major, if it is newer than the one installed.
#
# Steps 2 and 3 are best effort.  A rig is often on a bench with no route out,
# and it still has to program boards there, so every network step is gated on a
# reachability probe and every failure below leaves what is already on disk
# alone and exits 0.  This script must never be the reason the programmer does
# not start.
#
# Step 3 is how the binary reaches a rig.  The programmer source is not in this
# repo; its CI builds it inside each FPP image's rootfs and publishes the result
# here as a release asset per platform and FPP major, because the libraries it
# links change soname between the Debian releases the FPP majors are built on
# (libgpiodcxx.so.1 -> .so.2, libjsoncpp.so.25 -> .26).  Every boot with a
# network compares the published checksum against what is installed and
# downloads only on a change, so a rig follows CI without anyone committing a
# binary.  The `programmer` still committed here is a last resort for a rig
# that has never been online, and only runs if it happens to load on this OS.
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

# A rig gets its clock from the cape's RTC, so a bench rig with no board on it -
# or a dead cell - comes up in 1999 and every certificate reads as not yet
# valid: curl fails with rc 60 and the box looks offline when it is not.  That
# is why the pull below already passes http.sslVerify=false.  Try verified
# first and fall back only on a certificate error, so a rig with a good clock
# keeps a verified channel and one with a bad clock still updates.  Integrity
# of the binary itself does not rest on TLS either way - it is checked against
# the published sha256 below.
CURL_INSECURE=()
curl_get() {  # curl_get <outfile> <url> [extra curl args...]
    local out="$1" url="$2"; shift 2
    local rc
    curl -fsSL "${CURL_INSECURE[@]}" --connect-timeout 10 "$@" -o "$out" "$url" && return 0
    rc=$?
    # 60 unverifiable cert, 35 TLS handshake, 77 CA bundle unreadable.
    if [ ${#CURL_INSECURE[@]} -eq 0 ] && { [ $rc -eq 60 ] || [ $rc -eq 35 ] || [ $rc -eq 77 ]; }; then
        echo "check_for_new: TLS verification failed (curl $rc) with the clock at $(date '+%Y-%m-%d'); continuing unverified"
        CURL_INSECURE=(-k)
        curl -fsSL "${CURL_INSECURE[@]}" --connect-timeout 10 "$@" -o "$out" "$url" && return 0
        rc=$?
    fi
    return $rc
}

# One probe up front rather than letting git and curl each discover it the slow
# way.  Offline, the pull's retry loop would spend its ten attempts and the
# download its own retries, all to arrive where we already are: use what is on
# disk.  git's smart-http discovery endpoint is the same host and path the pull
# needs, so this tests what actually has to work.
probe_online() {
    curl_get /dev/null "${REPO_URL}/info/refs?service=git-upload-pack" --max-time 15
}

# FPP's images enable no wait-online service, so network-online.target is empty
# and this unit's After= on it is satisfied at once: the script runs while the
# interface is still coming up, and a cold boot reliably probes before DNS
# answers.  Waiting here for every rig would delay each boot of an offline one,
# and guessing from carrier or from a default route does not work - at this
# point in the boot both are as absent as DNS is, which is how two earlier
# attempts at this bailed out on precisely the boots they were written for.
#
# So do not decide up front.  Probe once, get on with it, and wait for the
# network only at the one place where being offline is fatal rather than
# merely unhelpful: needing a binary and not having one.  A rig that already
# has a working programmer never waits at all.
# Counts its own sleeps rather than reading the clock.  SECONDS follows wall
# time, and wall time on these rigs is not monotonic: the clock starts in 1999
# and chrony steps it 26 years forward partway through exactly this wait, which
# ends the loop on the spot and reported "network came up after 1928011s".  A
# backwards step would hang it for as long again.
wait_for_network() {
    local limit="${1:-90}" step=3 waited=0
    echo "check_for_new: no usable programmer on disk - waiting up to ${limit}s for the network"
    while [ "$waited" -lt "$limit" ]; do
        sleep "$step"
        waited=$(( waited + step ))
        # Quiet: an interface that is still coming up would otherwise log a
        # "could not resolve" line every three seconds for the whole wait.
        if probe_online 2>/dev/null; then
            echo "check_for_new: network came up after ${waited}s"
            return 0
        fi
    done
    echo "check_for_new: still no network after ${waited}s"
    return 1
}

# A short grace period, unconditionally.  On a cold boot the first probe
# essentially always fails -- FPP enables no wait-online service, so this runs
# before DNS answers -- and everything that needs the network hangs off this
# answer: the pull, and the clock sync below.  Probing once meant a rig whose
# committed binary happens to load never pulled at all on a cold boot.  The
# script this replaced retried its pull ten times at two-second intervals, so a
# grace period of this order is what rigs have always effectively had; it is
# only the earlier bail-out-on-first-miss that was new.  The much longer wait
# further down still exists for the case where being offline is fatal.
ONLINE=0
for attempt in 1 2 3 4 5 6 7; do
    if probe_online 2>/dev/null; then
        ONLINE=1
        [ "$attempt" -gt 1 ] && echo "check_for_new: network came up after $(( (attempt - 1) * 3 ))s"
        break
    fi
    [ "$attempt" -lt 7 ] && sleep 3
done
if [ "$ONLINE" != "1" ]; then
    echo "check_for_new: ${REPO_URL} is not reachable yet"
fi

# Set the clock before anything else uses it.
#
# The cape RTC is on i2c1 and only comes up when the programmer itself starts -
# after this script - so at this point the time is whatever the board powered on
# with: 1999 on one rig, a fixed stale 2024 date on another.  Everything
# downstream suffers for it.  Certificates read as not yet valid, every file the
# pull writes gets a bogus mtime, and the journal entries land outside the
# boot's own time range, so `journalctl -b` cannot show what this script did.
#
# There is no NTP answer available yet either: chrony is running but cannot
# select a source while the offset is decades, so `chronyc makestep` has nothing
# to step to.  What we do have is an HTTP response from a host we just reached,
# and its Date header is good to the second - ample for validating a
# certificate and for making a log readable.  chrony refines it from there.
sync_clock_from_server() {
    [ "$ONLINE" = "1" ] || return 0
    local hdr srv now delta
    hdr="$(curl -fsSI "${CURL_INSECURE[@]}" --connect-timeout 10 --max-time 20 "$REPO_URL" 2>/dev/null \
           | tr -d '\r' | awk 'tolower($1) == "date:" { sub(/^[^:]*: /, ""); print; exit }')"
    [ -n "$hdr" ] || return 0
    srv="$(date -u -d "$hdr" +%s 2>/dev/null)" || return 0
    [ -n "$srv" ] || return 0
    now="$(date -u +%s)"
    delta=$(( srv > now ? srv - now : now - srv ))
    # Leave a clock that is already close alone; chrony keeps it far better than
    # a header with one-second resolution can.
    [ "$delta" -gt 60 ] || return 0
    echo "check_for_new: clock is off by ${delta}s (reads $(date '+%Y-%m-%d %H:%M:%S')) - setting it from the server"
    date -u -s "@${srv}" >/dev/null 2>&1 || return 0
    hwclock -w >/dev/null 2>&1
    # Now that the offset is small, chrony can select a source and take over.
    chronyc makestep >/dev/null 2>&1
    echo "check_for_new: clock set to $(date '+%Y-%m-%d %H:%M:%S')"
    # A wrong clock is the usual reason verification failed above.  Now that it
    # is right, give TLS another chance rather than downloading the binary over
    # an unverified connection for the rest of the run.
    CURL_INSECURE=()
}
sync_clock_from_server

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
# The unit file this script is the ExecStartPre of.
#
# A pull ships programmer/kprogrammer.service, but systemd reads the copy under
# /usr/lib (or /etc), so an update that changes the unit reaches nothing until
# someone copies it by hand.  That matters here because ExecStart moved to
# start-programmer.sh: without this, a rig would pull the launcher, fetch
# programmer.local, and then go on running the committed binary directly and
# ignoring both.
#############################################################################
UNIT_SRC="${BASEDIR}/kprogrammer.service"
UNIT_DST="$(systemctl show -p FragmentPath --value kprogrammer.service 2>/dev/null)"
UNIT_CHANGED=0
if [ -f "$UNIT_SRC" ] && [ -n "$UNIT_DST" ] && [ -f "$UNIT_DST" ] \
   && ! cmp -s "$UNIT_SRC" "$UNIT_DST"; then
    if cp -f "$UNIT_SRC" "$UNIT_DST" 2>/dev/null; then
        echo "check_for_new: updated ${UNIT_DST}"
        systemctl daemon-reload
        UNIT_CHANGED=1
    else
        echo "check_for_new: could not write ${UNIT_DST}" >&2
    fi
fi


# A daemon-reload does not re-resolve ExecStart for the invocation that is
# already starting, so on the one boot where the unit changes systemd still
# launches the old ExecStart - the committed binary, i.e. precisely the thing
# that does not load on this rig.  Schedule a detached restart so that boot
# recovers rather than waiting for the next one.  systemd-run is what makes it
# safe: it outlives the service, where a "systemctl restart" run from inside
# this unit's own ExecStartPre would deadlock against it.  Bounded by
# construction - once the unit matches, UNIT_CHANGED is 0 and nothing is
# scheduled again.
schedule_restart_if_unit_changed() {
    [ "$UNIT_CHANGED" = "1" ] || return 0
    command -v systemd-run >/dev/null 2>&1 || return 0
    echo "check_for_new: the unit changed - restarting so the new ExecStart takes effect"
    systemd-run --quiet --on-active=2 --unit=kprogrammer-unit-refresh \
        systemctl restart kprogrammer.service >/dev/null 2>&1 || true
}


#############################################################################
# The programmer binary.
#
# start-programmer.sh runs programmer.local when it exists and the committed
# `programmer` otherwise.  programmer.local is what CI published for this
# platform and FPP major; .programmer-installed records which asset that was
# ("<PLAT>-<MAJ> <sha256 of the .gz>") so a boot can tell from checksums.txt
# alone whether there is anything new, without downloading the binary to find
# out.
#############################################################################
TARGET="${BASEDIR}/programmer.local"     # gitignored, so a pull cannot clobber it
MARKER="${BASEDIR}/.programmer-installed"
COMMITTED="${BASEDIR}/programmer"
rm -f "${BASEDIR}/.programmer-major"     # the marker an earlier version of this script kept

# A binary "runs" if the dynamic loader can resolve everything it needs.  This
# is the exact condition that fails across FPP majors, so testing it directly
# avoids executing the programmer (which would grab the OLED and the i2c bus)
# just to find out.  ldd's exit status matters as much as its output: a binary
# for the wrong architecture entirely reports "not a dynamic executable" and
# exits non-zero, with no "not found" line to grep for, so a pipeline into grep
# alone would call it loadable.
loads() {
    local out
    [ -x "$1" ] || return 1
    out="$(ldd "$1" 2>&1)" || return 1
    ! grep -q "not found" <<<"$out"
}

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
    schedule_restart_if_unit_changed
    exit 0
fi

ASSET="kl-programmer-oled-${PLAT}-${MAJ}.gz"
URL="${REPO_URL}/releases/download/fpp${MAJ}/${ASSET}"
SUMSURL="${REPO_URL}/releases/download/fpp${MAJ}/checksums.txt"

# What is installed, if it still runs.  The marker's platform/major half goes
# stale when a rig's card is reimaged onto another FPP major: the binary then
# fails to load and is replaced, which is what the check below produces too.
INSTALLED=""
if loads "$TARGET"; then
    INSTALLED="$(cat "$MARKER" 2>/dev/null)"
    case "$INSTALLED" in
        "${PLAT}-${MAJ} "*) INSTALLED="${INSTALLED#* }" ;;   # the sha
        *) INSTALLED="" ;;
    esac
fi

# Where being offline is merely unhelpful versus fatal.  With a binary that
# runs on disk - the installed one, or failing that the committed one - keep
# what we have.  With neither, the programmer is about to exit 127, and that
# is the one place worth waiting out a network that is still coming up.
have_runnable() {
    loads "$TARGET" || loads "$COMMITTED"
}
if [ "$ONLINE" != "1" ] && ! have_runnable && wait_for_network 90; then
    ONLINE=1
fi
if [ "$ONLINE" != "1" ]; then
    if loads "$TARGET"; then
        echo "check_for_new: offline - keeping the installed ${PLAT} programmer for FPP ${MAJ}"
    elif loads "$COMMITTED"; then
        echo "check_for_new: offline - no CI programmer installed, using the committed one"
    else
        echo "check_for_new: no ${PLAT} programmer for FPP ${MAJ} on disk and no network to fetch one." >&2
        echo "check_for_new: connect this rig to the network once to install it." >&2
    fi
    schedule_restart_if_unit_changed
    exit 0
fi

TMP="$(mktemp "${BASEDIR}/.programmer.XXXXXX.gz")"
SUMS="$(mktemp "${TMPDIR:-/tmp}/kprog.XXXXXX.sums")"
trap 'rm -f "$TMP" "${TMP%.gz}" "$SUMS"' EXIT

# checksums.txt is a few hundred bytes and names every asset of the release,
# so it answers "is there anything new" on its own.  Without it (an older
# release, or a fetch that failed) fall through to downloading the binary and
# comparing that.
EXPECTED=""
if curl_get "$SUMS" "$SUMSURL" --retry 3 --max-time 60; then
    EXPECTED="$(awk -v a="$ASSET" '$2 == a { print tolower($1); exit }' "$SUMS")"
    if [ -n "$EXPECTED" ] && [ -n "$INSTALLED" ] && [ "$EXPECTED" = "$INSTALLED" ]; then
        echo "check_for_new: ${PLAT} programmer for FPP ${MAJ} is current"
        schedule_restart_if_unit_changed
        exit 0
    fi
fi

# Verify before the download can replace a working binary.  The binaries and
# checksums.txt are separate assets, so a fetch landing mid-publish can see a
# mismatched pair; one re-fetch of both resolves that.
VERIFY="pending"
for ATTEMPT in 1 2; do
    if ! curl_get "$TMP" "$URL" --retry 3 --max-time 300; then
        echo "check_for_new: could not download ${URL}" >&2
        if loads "$TARGET"; then
            echo "check_for_new: keeping the installed programmer.local" >&2
        elif loads "$COMMITTED"; then
            echo "check_for_new: no rig binary published for ${PLAT} on FPP ${MAJ}; using the committed one" >&2
        else
            echo "check_for_new: no rig binary published for ${PLAT} on FPP ${MAJ}." >&2
        fi
        schedule_restart_if_unit_changed
        exit 0
    fi
    ACTUAL="$(sha256sum "$TMP" | cut -d' ' -f1)"
    if [ -z "$EXPECTED" ]; then
        # Nothing to verify against; the download itself is the only signal.
        [ -s "$SUMS" ] && VERIFY="unlisted" || VERIFY="no-checksums"
        break
    fi
    if [ "$ACTUAL" = "$EXPECTED" ]; then VERIFY="ok"; break; fi
    VERIFY="mismatch"
    if [ "$ATTEMPT" = "1" ]; then
        echo "check_for_new: checksum mismatch, re-fetching ..." >&2
        curl_get "$SUMS" "$SUMSURL" --retry 3 --max-time 60 \
            && EXPECTED="$(awk -v a="$ASSET" '$2 == a { print tolower($1); exit }' "$SUMS")"
    fi
done
case "$VERIFY" in
    ok)           echo "check_for_new: checksum verified for ${ASSET}" ;;
    no-checksums) echo "check_for_new: release fpp${MAJ} has no checksums.txt, skipping verification" ;;
    unlisted)     echo "check_for_new: WARNING: ${ASSET} not listed in checksums.txt" >&2 ;;
    *)
        echo "check_for_new: ERROR: checksum mismatch for ${ASSET}; keeping what is installed." >&2
        schedule_restart_if_unit_changed
        exit 0
        ;;
esac

# Only reachable without a checksums.txt answer: the binary had to be fetched
# to find out whether it changed.
if [ -n "$INSTALLED" ] && [ "$ACTUAL" = "$INSTALLED" ]; then
    echo "check_for_new: ${PLAT} programmer for FPP ${MAJ} is current"
    schedule_restart_if_unit_changed
    exit 0
fi

if ! gunzip -f "$TMP"; then
    echo "check_for_new: ERROR decompressing ${ASSET}" >&2
    schedule_restart_if_unit_changed
    exit 0
fi
# mktemp creates 0600 and mv preserves it; the programmer has to be executable.
chmod 755 "${TMP%.gz}"
# A published binary that does not load here (built against the wrong image,
# say) must not replace one that does.
if ! loads "${TMP%.gz}"; then
    echo "check_for_new: ERROR: the published ${ASSET} does not load on this FPP; keeping what is installed." >&2
    schedule_restart_if_unit_changed
    exit 0
fi
mv -f "${TMP%.gz}" "$TARGET"
echo "${PLAT}-${MAJ} ${ACTUAL}" > "$MARKER"
if [ -n "$INSTALLED" ]; then
    echo "check_for_new: updated the ${PLAT} programmer for FPP ${MAJ}"
else
    echo "check_for_new: installed the ${PLAT} programmer for FPP ${MAJ}"
fi
schedule_restart_if_unit_changed
exit 0
