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
% August 17, 2022

# NAME

${APP_NAME}

# SYNOPSIS

${APP_NAME} REPO_ID

# DESCRIPTION

Dump the Opensearch stats indexes for an Invenio RDM instance.
This script uses 'elasticdump' which is available from 

   <https://github.com/elasticsearch-dump/elasticsearch-dump>

and runs via npm/NodeJS.

# EXAMPLES

Backup the Opensearch for caltechdata running on CaltechDATA.

~~~shell
     sudo -u ubuntu ${APP_NAME} caltechdata
~~~

EOT

}

function backup_opensearch_to() {
	REPO_ID="$1"
	CONTAINER="${REPO_ID}_db_1"
	BACKUP_DIR="$2"
	#FIXME: Need to figure out how to identify the two indexes we want to backup to get the stats.
	if [ "${BACKUP_DIR}" = "" ]; then
		echo "Missing the backup directory name"
		exit 1
	fi
	if [ ! -d "${BACKUP_DIR}" ]; then
		echo "${BACKUP_DIR} does not exist"
		exit 1
	fi
	# We need to operating fetch and backup each index machine the repo name.
    curl http://localhost:9200/_settings | jq . \
         | grep "${REPO_ID}" | cut -d \" -f 2 | \
         grep -v provided_name | sort -u >"${BACKUP_DIR}/opensearch-indexes.txt"
      
    while read -r INDEX_NAME; do
		# Save the index mapping first, then save the data
    	elasticdump \
    		--input "http://localhost:9200/${INDEX_NAME}" \
    		--output "${BACKUP_DIR}/${INDEX_NAME}.mapping.json" \
    		--type mapping
    	gzip --force "${BACKUP_DIR}/${INDEX_NAME}.mapping.json"
    	elasticdump \
    	    --input "http://localhost:9200/${INDEX_NAME}" \
    	    --output "${BACKUP_DIR}/${INDEX_NAME}.data.json" \
    	    --type data
    	gzip --force "${BACKUP_DIR}/${INDEX_NAME}.data.json"
    done <"${BACKUP_DIR}/opensearch-indexes.txt"
}

function run_backups() {
	#
	# Sanity check our requiremented environment
	#
	SCRIPTNAME="$(readlink -f "$0")"
	DNAME="$(dirname "${SCRIPTNAME}")"
	cd "${DNAME}" || exit 1
	backup_opensearch_to "$1" "$2"
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
	mkdir -p opensearch-dumps
	run_backups "$1" "opensearch-dumps"
	;;
esac
