#!/usr/bin/env bash

##
# kopia-wrapper.sh
#
# Execute kopia backup policies (at intervals from cron). Output is captured,
# and notifications sent. At time of writing (2023-05) kopia server has no
# notification ability, and this is an absolute requirement for servers in
# production environments.
#
# Copyright 2023, Goya Pty Ltd
#
# Author: Gavin Stewart <gavin@goya.com.au>

# Requires the following tools to be available in the path:
#   bash
#   cat
#   tail
#   tee
#   awk
#   hostname

set -u

##
# Show usage
#
usage() {
    echo -n "
Version: ${KOPIA_WRAPPER_VERSION}
Usage: $(basename "$0") [-h|--help] <commands>
  -h          : This help.

  <commands>  : Run one or more space separated commands in order.
    snapshots           : Snapshot each kopia policy sequentially.
    maintenance-quick   : Quick maintenance.
    maintenance-full    : Full maintenance.

"
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
#   $1 Success|Failed - Success only if all kopia commands were successful.
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
#   KOPIA_WRAPPER_COMMAND_RESULTS
#
# Output:
#   - first line is KOPIA_WRAPPER_SUBJECT
#   - blank line
#   - if any command results exist:
#       - command result summary lines
#       - blank line
#   - Log Output heading
#
result_summary() {
    echo "${KOPIA_WRAPPER_SUBJECT}"
    echo ""
    if [[ -v KOPIA_WRAPPER_COMMAND_RESULTS[@] ]]; then
        echo "++ Command Summary ++"
        echo "----------------------"
        echo ""
        printf "%s\n" "${KOPIA_WRAPPER_COMMAND_RESULTS[@]}"
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
#   KOPIA_WRAPPER_COMMAND_FAILED
#   KOPIA_WRAPPER_NOTIFY
#   KOPIA_WRAPPER_LOG
#   KW_NOTIFY
#
notify_and_clean() {
    stop_logfile

    if [[ "${KOPIA_WRAPPER_COMMAND_FAILED}" == "false" ]] &&
            [[ "${KW_NOTIFY}" == "ERRORS" ]]; then
        # No commands failed, and notify only on errors, clean up and return.
        rm -f "${KOPIA_WRAPPER_LOG}"
        return
    fi

    if [[ "${KOPIA_WRAPPER_COMMAND_FAILED}" == "true" ]]; then
        parse_notification_vars "Failed"
    else
        parse_notification_vars "Success"
    fi

    if [[ ${#KOPIA_WRAPPER_NOTIFY[@]} -gt 0 ]]; then
        # A notification command was provided in config
        {
            result_summary

            cat "${KOPIA_WRAPPER_LOG}"
        } | "${KOPIA_WRAPPER_NOTIFY[@]}"
    else
        # No notification command, just send to stdout
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
read_elapsed_time() {
    tail -1 "${KOPIA_WRAPPER_LOG}" | awk '/^-- Elapsed time:/ { print $4 }'
}

##
# Execute provided kopia command, capturing elapsed time and return codes.
#
# Output:
#   Kopia execution output
#
# Globals:
#   KOPIA_WRAPPER_COMMAND_FAILED - set true if kopia command returns non-zero.
#   KOPIA_WRAPPER_COMMAND_RESULTS - summarised result of command appended.
#
# Parameters:
#   $@ - command line parameters to pass quoted to kopia executable
#
run_kopia_command() {
    declare -a kopia_command=("$@")

    local ret time_elapsed result_string
    echo "++ kopia" "${kopia_command[@]}"
    echo "-------------------------------------------------------------------"
    echo "-- Start time: $(date '+%Y-%m-%d %H:%M:%S') --"
    env time -f "-- Elapsed time: %E --" \
        "${KW_EXECUTABLE}" "${kopia_command[@]}"
    ret=$?
    time_elapsed=$(read_elapsed_time)
    echo ""

    result_string="Success"
    if [[ ${ret} -ne 0 ]]; then
        KOPIA_WRAPPER_COMMAND_FAILED="true"
        result_string="Failed"
    fi

    if [[ ! -v KOPIA_WRAPPER_COMMAND_RESULTS[@] ]]; then
        # Add header before we add first result
        local header
        header=$(
            printf "%-8s | %4s | %11s | %s\n" \
                    "Result" "Code" "Elapsed" "Command"
            printf "%-8s + %4s + %11s + %s" \
                    "--------" "----" "-----------" "-------"
        )
        KOPIA_WRAPPER_COMMAND_RESULTS+=( "${header}" )
    fi
    result_string=$(
        printf "%-8s | %4s | %11s | " \
               "${result_string}" "${ret}" "${time_elapsed}"
        echo "${kopia_command[@]}"
    )
    KOPIA_WRAPPER_COMMAND_RESULTS+=("${result_string}")
}

##
# Generate kopia snapshot commands, and execute each sequentially.
#
run_snapshots_command() {
    # Gather kopia policies, ignore the one called "(global)"
    declare -a kopia_policies
    readarray -t kopia_policies < <(
                                        "${KW_EXECUTABLE}" policies list |
                                        awk '{print $2}' |
                                        grep -v "\(global\)"
                                    )

    # Foreach policy, generate command and execute.
    for policy in "${kopia_policies[@]}"; do
        local policy_path kopia_command
        policy_path="${policy#*:}"
        kopia_command=(
            "snapshot"
            "create"
            "--force-enable-actions"
            "--no-progress"
            "${policy_path}"
        )
        run_kopia_command "${kopia_command[@]}"
    done
}

##
# Generate kopia maintenance command, and execute it.
#
# Parameters:
#   $1 quick|full
#
run_maintenance_command() {
    local maintenance_opt
    case "$1" in
        full)
            maintenance_opt="--full"
            ;;
        *)
            maintenance_opt="--no-full"
            ;;
    esac

    declare -a kopia_command
    kopia_command=(
        "maintenance"
        "run"
        "${maintenance_opt}"
    )

    run_kopia_command "${kopia_command[@]}"
}

##
# Send first parameter to stderr, and exit with second parameter.
#
# Parameters:
#   $1 - String to send to stderr
#   $2 - Exit code
#
error_exit() {
    echo "$1" 1>&2
    exit $2
}

##
# Main function
#
# Globals:
#   KOPIA_WRAPPER_HOME - Calculated parent directory of this script's dir.
#   KOPIA_WRAPPER_COMMANDS - from command line parameters.
#   KOPIA_WRAPPER_COMMAND_FAILED - false, set true if any command fails.
#   KOPIA_WRAPPER_VERSION
#   Variables defined in kopia-wrapper.conf
#
# Parameters:
#   $@ - All command line parameters passed in to script.
#
main() {
    KOPIA_WRAPPER_HOME="$(realpath -z "$0" | xargs -0 dirname -z | xargs -0 dirname)"
    readonly KOPIA_WRAPPER_HOME

    source "${KOPIA_WRAPPER_HOME}/kopia-wrapper.conf" ||
        error_exit "Failed to read kopia-wrapper.conf" 1

    # Ensure kopia environment is configured
    set -o allexport
    source "${KOPIA_WRAPPER_HOME}/kopia-environment.conf" ||
        error_exit "Failed to read kopia-environment.conf" 1
    set +o allexport

    KOPIA_WRAPPER_VERSION="Unknown"
    read -r KOPIA_WRAPPER_VERSION <"${KOPIA_WRAPPER_HOME}/VERSION" ||
        error_exit "Failed to read VERSION" 1
    readonly KOPIA_WRAPPER_VERSION

    parse_parameters "$@"

    KOPIA_WRAPPER_COMMAND_FAILED="false"

    # Make sure we are the only instance of this script running.
    exec 234< $0
    if ! flock -n -x 234; then
        echo "$$: $0: failed to get lock, exiting."
        exit 1
    fi

    start_logfile

    trap notify_and_clean EXIT

    for command in "${KOPIA_WRAPPER_COMMANDS[@]}"; do
        case "${command}" in
            snapshots)
                run_snapshots_command
                ;;
            maintenance-quick)
                run_maintenance_command "quick"
                ;;
            maintenance-full)
                run_maintenance_command "full"
                ;;
            *)
                # Ignore
                ;;
        esac
    done
}

main "$@"
