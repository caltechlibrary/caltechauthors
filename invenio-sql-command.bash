#!/bin/bash
APP_NAME="$(basename "$0")"

#
# This script can bring invenio-rdm down in an orderly fashion
# or start it back up.
#

function usage() {
	cat <<EOT
% ${APP_NAME}() ${APP_NAME} user manual
% R. S. Doiel
% August 11, 2025

# NAME

${APP_NAME}

# SYNOPSIS

${APP_NAME} CONTAINER_NAME BACKUP_DIR

# DESCRIPTION

Dump the Postgres databases for CONTAINER_NAME into BACKUP_DIR.
CONTAINER_NAME is the name of your Invenio instance and will be
used as the prefix to the backup up filename.

# EXAMPLES

Backup the Postgres running in 'caltechdata_db_1' and write them
to '/var/backups/postgres'.

~~~shell
	bash ${APP_NAME}  caltechauthors_db_1 'SELECT json from vocabularies_metadata;'
~~~

EOT

}

function run_command() {
	DOCKER="$1"
	CONTAINER="$2"
	COMMAND="$3"
	if [ "${CONTAINER}" = "" ]; then
		echo "Missing the container name"
		exit 1
	fi
	$DOCKER container exec \
		"${CONTAINER}" /usr/bin/psql \
		--username="${DB_USERNAME}" \
		-d "${DB_NAME}" -c "${COMMAND}"
	}

function run_all() {
	#
	# Sanity check our requiremented environment
	#
	SCRIPTNAME="$(readlink -f "$0")"
	DNAME="$(dirname "${SCRIPTNAME}")"
	cd "${DNAME}" || exit 1
	# Source the file "postgres_env.cfg" it contains the
	# value $DB_USERNAME.
	if [ -f postgres_env.cfg ]; then
		. postgres_env.cfg
	fi
	if [ "$DB_NAME" = "" ]; then
		echo "The environment variable DB_NAME is not set."
		exit 1
	fi
	if [ "$DB_USERNAME" = "" ]; then
		echo "The environment variable DB_USERNAME is not set."
		exit 1
	fi

	DOCKER="/usr/bin/docker"
	if [ ! -f "${DOCKER}" ]; then
		DOCKER=$(which docker)
	fi
	if [ "${DOCKER}" = "" ]; then
		echo "Cannot find docker program, aborting"
		exit 1
	fi
	run_command "$DOCKER" "$1" "$2"
}

#
# Main entry script point.
#
case "$1" in
h | help | -h | --help)
	usage
	exit 0
	;;
*)
	if [ "$1" = "" ]; then
		usage
		exit 1
	fi
	run_all "$1" "$2"
	;;
esac
