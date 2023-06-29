#!/usr/bin/env bash

##
# Kopia Action script to dump Virtualmin (Webmin) MySQL database.
#
# Copyright 2023 Goya Pty Ltd.
#
# Author: Gavin Stewart <gavin@goya.com.au>

# Configurable vars:
WEBMIN_MYSQL_CONFIG="/etc/webmin/mysql/config"
DUMP_DIR="/home/mysqldumps"
DUMP_DIR_PERMS="0700"
DUMP_FILE="kopia-wrapper_virtualmin.sql.gz"
DUMP_ROTATIONS=5

# User and Password will be automatically determined from webmin.
MYSQLDUMP=(
    "/usr/bin/mysqldump"
    "--all-databases"
    "--ignore-table=mysql.event"
)

COMPRESSOR=(
	"/bin/gzip"
    "-9"
    "--rsyncable"
)

# Ensure dump directory exists, and has correct perms.
if [[ ! -d "${DUMP_DIR}" ]]; then
    mkdir -p "${DUMP_DIR}" || exit 1
    chmod "${DUMP_DIR_PERMS}" "${DUMP_DIR}"
fi

# Extract credentials from webmin.
# MYSQL_PWD is a magic env var that must be exported for mysqldump to use.
declare -x MYSQL_PWD
MYSQL_PWD=$(/usr/bin/awk -F '=' '/^pass=/ {print $2}' "${WEBMIN_MYSQL_CONFIG}") || exit 1
MYSQL_USR=$(/usr/bin/awk -F '=' '/^login=/ {print $2}' "${WEBMIN_MYSQL_CONFIG}") || exit 1

# Rotate previous copies of dump file.
if [[ -e "${DUMP_DIR}/${DUMP_FILE}" ]] && [[ $DUMP_ROTATIONS -gt 0 ]]; then
    for ((i=DUMP_ROTATIONS-1; i > 0; i--)); do
        if [[ -e "${DUMP_DIR}/${DUMP_FILE}.${i}" ]]; then
            mv -f "${DUMP_DIR}/${DUMP_FILE}.${i}" "${DUMP_DIR}/${DUMP_FILE}.$((i+1))"
        fi
    done
    mv -f "${DUMP_DIR}/${DUMP_FILE}" "${DUMP_DIR}/${DUMP_FILE}.1"
fi

# Dump mysql database and compress.
"${MYSQLDUMP[@]}" -u "${MYSQL_USR}" | "${COMPRESSOR[@]}" > "${DUMP_DIR}/${DUMP_FILE}"

# Exit with the exit code from mysqldump.
exit "${PIPESTATUS[0]}"

