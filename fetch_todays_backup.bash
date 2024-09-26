#!/bin/bash
#

function help() {
    APP_NAME=$(basename "$0")
    cat <<EOT

# NAME

  ${APP_NAME}

# SYNOPSIS

  ${APP_NAME} RMD_HOST_NAME REPO_ID

# DESCRIPTION

${APP_NAME} will retrieve a gzipped SQL backup for current day from
datawork.library.caltech.edu. 

# EXAMPLE

~~~shell
  ${APP_NAME} authors.library.caltech.edu caltechauthors
~~~

EOT
}

function fetch_backup() {
    RDM_HOST_NAME="$1"
    REPO_ID="$2"
    YYYYMMDD=$(date +%Y-%m-%d)

    FNAME="${REPO_ID}_db_1-${REPO_ID}-${YYYYMMDD}.sql"
    if [ -f "${FNAME}" ]; then
        echo "Using existing ${FNAME}"
    elif [ -f "${FNAME}.gz" ]; then
        echo "Using existing ${FNAME}.gz"
    else
        echo "Fetching ${FNAME}.gz"
        scp "datawork.library.caltech.edu:/storage/SQL_Backups/${RDM_HOST_NAME}/Daily/${FNAME}.gz" ./
    fi
    if [ -f "${FNAME}.gz" ]; then
        echo "Gunzipping ${FNAME}.gz"
        gunzip "${FNAME}.gz"
    fi
}

#
# Main
#
if [ "$#" != "2" ]; then
    help
    exit 1
fi

#
# Main entry script point.
#
case "$1" in
h | help | -h | --help)
    help
    exit 0
    ;;
*)
    if [ "$1" = "" ]; then
        help
        exit 1
    fi
    fetch_backup "$1" "$2"
    ;;
esac
