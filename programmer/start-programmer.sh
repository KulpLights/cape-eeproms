#!/bin/bash
#############################################################################
# ExecStart for kprogrammer.service.
#
# Prefer programmer.local - the build check_for_new.sh fetched for this rig's
# platform and FPP major - over the `programmer` committed here, which is a
# single build and only loads on the FPP major it was built against.  Same
# shape as the set_cape_sn_in_eeprom.local override: *.local is gitignored, so
# a pull can neither clobber it nor be blocked by it.
#############################################################################

cd "$(dirname "${BASH_SOURCE[0]:-$0}")" || exit 1

if [ -x ./programmer.local ]; then
    exec ./programmer.local "$@"
fi
exec ./programmer "$@"
