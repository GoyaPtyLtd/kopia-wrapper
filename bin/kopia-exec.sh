#!/usr/bin/env bash

##
# kopia-exec.sh
#
# Execute kopia with the required environment variables set.
# (see: kopia-environment.conf)
#
# Copyright 2023, Goya Pty Ltd
#
# Author: Gavin Stewart <gavin@goya.com.au>

##
# Main function
#
# Globals:
#   KOPIA_WRAPPER_HOME - Calculated parent directory of this script's dir.
#   Variables defined in kopia-wrapper.conf
#
main() {
    KOPIA_WRAPPER_HOME="$(realpath -z "$0" | xargs -0 dirname -z | xargs -0 dirname)"
    readonly KOPIA_WRAPPER_HOME

    source "${KOPIA_WRAPPER_HOME}/kopia-wrapper.conf" || exit 1

    # Ensure kopia environment is configured
    set -o allexport
    source "${KOPIA_WRAPPER_HOME}/kopia-environment.conf" || exit 1
    set +o allexport

    exec "${KW_EXECUTABLE}" "$@"
}

main "$@"
