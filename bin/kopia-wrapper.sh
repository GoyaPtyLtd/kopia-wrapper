#!/usr/bin/env bash

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

##
# Show usage
#
usage() {
    cat <<EO_USAGE

Usage: $(basename "$0") [-h|--help] <commands>
  -h          : This help.

  <commands>  : Run one or more space separated commands in order.
    snapshots           : Snapshot each kopia policy sequentially.
    maintenance-quick   : Quick maintenance.
    maintenance-full    : Full maintenance.

EO_USAGE
}

##
# Parse command line parameters
#
# Globals:
#   KOPIA_WRAPPER_COMMANDS
#
# Output: none
parse_parameters() {
    declare -ga KOPIA_WRAPPER_COMMANDS=()

    while [[ $# -ge 1 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit
                ;;
            snapshots|maintenance-quick|maintenance-full)
                KOPIA_WRAPPER_COMMANDS+=("$1")
                ;;
            *)
                usage
                exit 2
                ;;
        esac
        shift
    done

    # Ensure at least one command given
    if [[ ${#KOPIA_WRAPPER_COMMANDS[@]} -lt 1 ]]; then
        usage
        exit 2
    fi
}

##
# Parse notification subject and command from config file
#
# Globals:
#   KOPIA_WRAPPER_SUBJECT
#   KOPIA_WRAPPER_NOTIFY
#   Variables defined in kopia-wrapper.conf
#
# Parameters:
#   $1 STATUS Success|Failed
#
# Output: none
parse_notification_vars() {
    local STATUS="$1"

    local HOSTLONG HOSTSHORT
    HOSTLONG="$(hostname -f)"
    HOSTSHORT="$(hostname -s)"

    KOPIA_WRAPPER_SUBJECT="${KW_SUBJECT}"
    KOPIA_WRAPPER_SUBJECT="${KOPIA_WRAPPER_SUBJECT//%STATUS%/${STATUS}}"
    KOPIA_WRAPPER_SUBJECT="${KOPIA_WRAPPER_SUBJECT//%HOSTLONG%/${HOSTLONG}}"
    KOPIA_WRAPPER_SUBJECT="${KOPIA_WRAPPER_SUBJECT//%HOSTSHORT%/${HOSTSHORT}}"

    # Note the eval here. This is used to bring the KW_NOTIFY_CMD string from
    # the config file into an array for execution with parameters that
    # may contain spaces.
    #
    # Example KW_NOTIFY_CMD string from kopia-wrapper.conf:
    #   "mail -s '[Kopia] %SUBJECT%' user@example.com"
    #
    # This will create:
    #   KOPIA_WRAPPER_NOTIFY[0]="mail"
    #   KOPIA_WRAPPER_NOTIFY[1]="-s"
    #   KOPIA_WRAPPER_NOTIFY[2]="[Kopia] %SUBJECT%"
    #   KOPIA_WRAPPER_NOTIFY[3]="user@example.com"
    #
    # %SUBJECT% will be expanded, and may also contain spaces.
    #
    # This will be executed with quoted parameters later as:
    #   "${KOPIA_WRAPPER_NOTIFY[@]}"
    #
    declare -ga KOPIA_WRAPPER_NOTIFY
    eval "KOPIA_WRAPPER_NOTIFY=(${KW_NOTIFY_CMD})"

    KOPIA_WRAPPER_NOTIFY=("${KOPIA_WRAPPER_NOTIFY[@]//%STATUS%/${STATUS}}")
    KOPIA_WRAPPER_NOTIFY=("${KOPIA_WRAPPER_NOTIFY[@]//%HOSTLONG%/${HOSTLONG}}")
    KOPIA_WRAPPER_NOTIFY=("${KOPIA_WRAPPER_NOTIFY[@]//%HOSTSHORT%/${HOSTSHORT}}")
    KOPIA_WRAPPER_NOTIFY=("${KOPIA_WRAPPER_NOTIFY[@]//%SUBJECT%/${KOPIA_WRAPPER_SUBJECT}}")
}

##
# Set up log file for all script output.
#
# Globals:
#   KOPIA_WRAPPER_LOG
#
setup_logfile() {
    KOPIA_WRAPPER_LOG="/tmp/kopia-wrapper.$$.log"

    # Save original stdout, stderr
    exec 101>&1
    exec 102>&2

    if [[ -t 1 ]]; then
        # stdout is a terminal, send output there too in addition to file
        exec &> >(tee -i "${KOPIA_WRAPPER_LOG}")
    else
        # stdout is not a terminal, just log all output to file
        exec &> "${KOPIA_WRAPPER_LOG}"
    fi
}

##
# Stop directing script output to log file.
#
stop_logfile() {
    # Recover original stdout, stderr
    exec 1>&101 101>&-
    exec 2>&102 102>&-
}

##
# Summary for top of notification
#
# Output:
#   - subject is first line
#   - summary of snapshot/maintenance results follows
#
result_summary() {
    echo "${KOPIA_WRAPPER_SUBJECT}"
    echo ""
    if [[ -v KOPIA_WRAPPER_SNAPSHOT_RESULTS[@] ]]; then
        echo " + Snapshot results:"
        echo "${KOPIA_WRAPPER_SNAPSHOT_RESULTS[@]}"
        echo ""
    fi
    if [[ -v KOPIA_WRAPPER_MAINTENANCE_RESULTS[@] ]]; then
        echo " + Maintenance results:"
        echo "${KOPIA_WRAPPER_MAINTENANCE_RESULTS[@]}"
        echo ""
    fi
    echo " + Log Output:"
    echo ""
}

##
# Send results as notification as defined in config. Clean up temporary
# files.
#
# Globals:
#   KOPIA_WRAPPER_STATUS
#   KOPIA_WRAPPER_SUBJECT
#   KOPIA_WRAPPER_NOTIFY
#   KOPIA_WRAPPER_LOG
#
notify_and_clean() {
    stop_logfile

    if [[ -z "${KOPIA_WRAPPER_STATUS}" ]]; then
        KOPIA_WRAPPER_STATUS="Failed"
    fi

    parse_notification_vars "${KOPIA_WRAPPER_STATUS}"

    if [[ ${#KOPIA_WRAPPER_NOTIFY[@]} -gt 0 ]]; then
        # A notification command was provided in config
        {
            result_summary

            cat "${KOPIA_WRAPPER_LOG}"
        } | "${KOPIA_WRAPPER_NOTIFY[@]}"
    else
        # No notification command, just output
        {
            result_summary

            cat "${KOPIA_WRAPPER_LOG}"
        }
    fi

    rm -f "${KOPIA_WRAPPER_LOG}"
}

##
# Iterate kopia policies and perform a snapshot for each sequentially.
#
# Globals:
#   KOPIA_WRAPPER_STATUS - Set to "Failed" if any one snapshot fails.
#   KOPIA_WRAPPER_SNAPSHOT_RESULTS - Result of each individual snapshot.
#
do_snapshots() {
    # Gather kopia policies, ignore the one called "(global)"
    declare -a kopia_policies
    readarray -t kopia_policies < <(
                                        kopia policies list |
                                        awk '{print $2}' |
                                        grep -v "\(global\)"
                                    )

    # Foreach policy, snapshot
    local policy RET
    for policy in "${kopia_policies[@]}"; do
        echo " + Running kopia snapshot for policy: ${policy}"
        echo " + ----------------------------------"
        local policy_path="${policy#*:}"
        kopia snapshot "${policy_path}"
        RET=$?
        echo ""

        if [[ ${RET} -eq 0 ]]; then
            KOPIA_WRAPPER_SNAPSHOT_RESULTS+=(" + Success: ${policy}")
        else
            KOPIA_WRAPPER_SNAPSHOT_RESULTS+=(" + Failed(${RET}): ${policy}")
            KOPIA_WRAPPER_STATUS="Failed"
        fi

    done
}

##
# Perform a kopia maintenance run
#
# Globals:
#   KOPIA_WRAPPER_STATUS - Set to "Failed" on maintenance failure.
#   KOPIA_WRAPPER_MAINTENANCE_RESULTS
#
# Parameters:
#   $1 quick|full
do_maintenance() {
    local MAINTENANCE_TYPE=$1

    echo " + Doing kopia maintenance - ${MAINTENANCE_TYPE}"
    echo ""

    #kopia maintenance run --full
}

##
# Main function
#
# Globals:
#   KOPIA_WRAPPER_HOME
#   KOPIA_WRAPPER_STATUS
#   Variables defined in kopia-wrapper.conf
#
main() {
    KOPIA_WRAPPER_HOME="$(realpath -z "$0" | xargs -0 dirname -z | xargs -0 dirname)"
    readonly KOPIA_WRAPPER_HOME

    source "${KOPIA_WRAPPER_HOME}/kopia-wrapper.conf" || exit 1

    parse_parameters "$@"

    KOPIA_WRAPPER_STATUS="Success"

    # Make sure we are the only instance of this script running.
    exec 234< $0
    if ! flock -n -x 234; then
        echo "$$: $0: failed to get lock, exiting."
        exit 1
    fi

    setup_logfile

    trap notify_and_clean EXIT

    declare -ga KOPIA_WRAPPER_SNAPSHOT_RESULTS
    declare -ga KOPIA_WRAPPER_MAINTENANCE_RESULTS
    for command in "${KOPIA_WRAPPER_COMMANDS[@]}"; do
        case "${command}" in
            snapshots)
                do_snapshots
                ;;
            maintenance-quick)
                do_maintenance "quick"
                ;;
            maintenance-full)
                do_maintenance "full"
                ;;
            *)
                # Ignore
                ;;
        esac
    done
}

main "$@"
