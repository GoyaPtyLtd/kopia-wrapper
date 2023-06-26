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
# Start a log file for all script output.
#
# Globals:
#   KOPIA_WRAPPER_LOG
#
start_logfile() {
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
# Output a summary of execution results.
#
# Globals:
#   KOPIA_WRAPPER_SUBJECT
#   KOPIA_WRAPPER_SNAPSHOT_RESULTS
#   KOPIA_WRAPPER_MAINTENANCE_RESULTS
#
# Output:
#   - first line is KOPIA_WRAPPER_SUBJECT
#   - second line is blank
#   - following lines:
#     - snapshot summary, if any exist
#     - maintenance summary, if any exist
#
result_summary() {
    echo "${KOPIA_WRAPPER_SUBJECT}"
    echo ""
    if [[ -v KOPIA_WRAPPER_SNAPSHOT_RESULTS[@] ]]; then
        echo "++ Snapshot Summary ++"
        echo "----------------------"
        printf "%s\n" "${KOPIA_WRAPPER_SNAPSHOT_RESULTS[@]}"
        echo ""
    fi
    if [[ -v KOPIA_WRAPPER_MAINTENANCE_RESULTS[@] ]]; then
        echo "++ Maintenance Summary ++"
        echo "-------------------------"
        printf "%s\n" "${KOPIA_WRAPPER_MAINTENANCE_RESULTS[@]}"
        echo ""
    fi
    echo "++ Log Output ++"
    echo "----------------"
    echo ""
}

##
# Send notification of execution as defined in config. Clean up temporary
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
            echo "++ No notification command configured, sending to stdout ++"
            echo "-----------------------------------------------------------"

            result_summary

            cat "${KOPIA_WRAPPER_LOG}"
        }
    fi

    rm -f "${KOPIA_WRAPPER_LOG}"
}

##
# Read the time elapsed from the last line of the log file.
#
# Output:
#   Extracted time elapsed from log file if found, else empty string.
#
# Globals:
#   KOPIA_WRAPPER_LOG
#
read_time_elapsed() {
    tail -1 "${KOPIA_WRAPPER_LOG}" | awk '/^Time elapsed:/ { print $3 }'
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
                                        "${KW_EXECUTABLE}" policies list |
                                        awk '{print $2}' |
                                        grep -v "\(global\)"
                                    )

    # Foreach policy, snapshot
    for policy in "${kopia_policies[@]}"; do
        local policy_path ret time_elapsed result_string

        echo "++ kopia snapshot create ${policy}"
        echo "----------------------------------------------------------------"
        policy_path="${policy#*:}"
        env time -f "\nTime elapsed: %E" \
            "${KW_EXECUTABLE}" snapshot create "${policy_path}"
        ret=$?
        time_elapsed=$(read_time_elapsed)
        echo ""

        if [[ ${ret} -eq 0 ]]; then
            result_string="Success"
        else
            result_string="Failed"
            KOPIA_WRAPPER_STATUS="Failed"
        fi

        if [[ ! -v KOPIA_WRAPPER_SNAPSHOT_RESULTS[@] ]]; then
            # Add header before we add first result
            local header
            header=$(
                printf "%-8s | %4s | %11s | %s\n" \
                       "Result" "Code" "Time" "Policy"
                printf "%-8s + %4s + %11s + %s" \
                       "--------" "----" "-----------" "-------"
            )
            KOPIA_WRAPPER_SNAPSHOT_RESULTS+=( "${header}" )
        fi
        result_string=$(
            printf "%-8s | %4s | %11s | %s" \
                   "${result_string}" "${ret}" "${time_elapsed}" "${policy}"
        )
        KOPIA_WRAPPER_SNAPSHOT_RESULTS+=( "${result_string}" )
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
    local maintenance_type=$1

    local maintenance_opt ret time_elapsed result_string
    case "${maintenance_type}" in
        full)
            maintenance_opt="--full"
            ;;
        *)
            maintenance_opt="--no-full"
            ;;
    esac

    echo "++ kopia maintenance run ${maintenance_opt}"
    echo "-------------------------------"
    env time -f "\nTime elapsed: %E" \
        "${KW_EXECUTABLE}" maintenance run "${maintenance_opt}"
    ret=$?
    time_elapsed=$(read_time_elapsed)
    echo ""

    if [[ ${ret} -eq 0 ]]; then
        result_string="Success"
    else
        result_string="Failed"
        KOPIA_WRAPPER_STATUS="Failed"
    fi

    if [[ ! -v KOPIA_WRAPPER_MAINTENANCE_RESULTS[@] ]]; then
        # Add header before we add first result
        local header
        header=$(
            printf "%-8s | %4s | %11s | %s\n" \
                    "Result" "Code" "Time" "Type"
            printf "%-8s + %4s + %11s + %s" \
                    "--------" "----" "-----------" "-----"
        )
        KOPIA_WRAPPER_MAINTENANCE_RESULTS+=( "${header}" )
    fi
    result_string=$(
        printf "%-8s | %4s | %11s | %s" \
               "${result_string}" "${ret}" "${time_elapsed}" "${maintenance_type}"
    )
    KOPIA_WRAPPER_MAINTENANCE_RESULTS+=("${result_string}")
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

    start_logfile

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
