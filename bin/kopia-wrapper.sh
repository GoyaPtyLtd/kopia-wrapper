#!/bin/bash

##
# kopia-wrapper.sh
#
# Execute kopia backup policies (at intervals from cron). Output is captured,
# and notifications sent. At time of writing (2023-05) kopia server has no
# notification ability, and this is an absolute requirement for servers in
# production environments.
#
# Copyright 2023, Gavin Stewart, Goya Pty Ltd

set -u

main() {
    # Source config
    source "$(realpath "$0" | xargs dirname)/../kopia-wrapper.conf"

    local STATUS HOSTLONG HOSTSHORT SUBJECT
    STATUS="Success"
    HOSTLONG="$(hostname -f)"
    HOSTSHORT="$(hostname -s)"

    SUBJECT="${KW_SUBJECT}"
    SUBJECT="${SUBJECT//%STATUS%/${STATUS}}"
    SUBJECT="${SUBJECT//%HOSTLONG%/${HOSTLONG}}"
    SUBJECT="${SUBJECT//%HOSTSHORT%/${HOSTSHORT}}"

    echo "Subject:" "$SUBJECT"

    declare -a NOTIFY_CMD
    eval "NOTIFY_CMD=(${KW_NOTIFY_CMD})"

    NOTIFY_CMD=("${NOTIFY_CMD[@]//%STATUS%/${STATUS}}")
    NOTIFY_CMD=("${NOTIFY_CMD[@]//%HOSTLONG%/${HOSTLONG}}")
    NOTIFY_CMD=("${NOTIFY_CMD[@]//%HOSTSHORT%/${HOSTSHORT}}")
    NOTIFY_CMD=("${NOTIFY_CMD[@]//%SUBJECT%/${SUBJECT}}")

    printf "got: %s\n" "${NOTIFY_CMD[@]}"
}

main "$@"
