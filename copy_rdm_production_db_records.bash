#!/bin/bash
#

APP_NAME="$(basename "$0")"

WORK_DIR="$(dirname "$0")"
cd "${WORK_DIR}" || exit 1

function display_help() {
    cat <<HELP
% ${APP_NAME}(1) user manual
% R. S. Doiel
% 2025-05-06

# NAME

${APP_NAME}

# SYNOPIS

${APP_NAME}

# DESCRIPTION

${APP_NAME} fetches and copies the RDM records for CaltechAUTHORS
via a Postgres SQL dump from our production systems.

- authors.library.caltech.edu

# OPTIONS

-h, --help
: display this help page.


# EXAMPLE

~~~shell
${APP_NAME}
~~~

HELP
}

case "$1" in
  -h|--help|help)
  display_help
  exit 0;
  ;;
esac

# Fetch Today's SQL dumps
YMD=$(date +%Y-%m-%d)
if [ ! -d rdm-sql-dumps ]; then
	mkdir -p rdm-sql-dumps
fi

function copy_dump_for_import() {
	HOST="${1}"
	YMD="${2}"
	DUMP_PREFIX="caltech$(echo "${HOST}" | awk -F[/.] '{print $1}')-dump"
	case "${DUMP_PREFIX}" in
		caltechauthors-dump | caltechdata-dump)
		echo "Copying ${DUMP_PREFIX} for ${YMD}"
		cp -v "rdm-sql-dumps/${DUMP_PREFIX}_${YMD}.sql.gz" "${DUMP_PREFIX}.sql.gz"
		gunzip "${DUMP_PREFIX}.sql.gz"
		;;
		*)
		echo "Skipping, unknown host ${HOST}, dump prefix ${DUMP_PREFIX}"
		;;
	esac
}

# After backup is done fetch the result
function fetch_rdm_backups() {
	HOST="${1}"
	DUMP_PREFIX="caltech$(echo "${HOST}" | awk -F[/.] '{print $1}')-dump"
	# Check if we need to do fetch.
	if [ -f "rdm-sql-dumps/${DUMP_PREFIX}_${YMD}.sql.gz" ]; then
		copy_dump_for_import "${HOST}" "${YMD}"
	else
		echo "$(date) scp ${HOST}:sql-dumps/${DUMP_PREFIX}_${YMD}.sql.gz ./rdm-sql-dumps/"
		scp "${HOST}:sql-dumps/${DUMP_PREFIX}_${YMD}.sql.gz" ./rdm-sql-dumps/
		copy_dump_for_import "${HOST}" "${YMD}"
	fi
	echo "$(date): fetch for RDM repositories completed"
}

#
# Main
#
fetch_rdm_backups authors.library.caltech.edu
