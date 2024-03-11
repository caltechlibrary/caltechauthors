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

Restore the Opensearch indexes for an Invenio RDM instance from
a opensearch-dump directory. It uses the "opensearch-indexes.txt" for
the index list. If you want to only restore some of the index you should
edit the "opensearch-indexes.txt" file accordingly.

This script uses 'elasticdump' which is available from 

   <https://github.com/elasticsearch-dump/elasticsearch-dump>

and runs via npm/NodeJS.

# EXAMPLES

Restore the Opensearch for caltechdata running on CaltechDATA.

~~~shell
     sudo -u ubuntu ${APP_NAME} caltechdata
~~~

EOT

}

function restore_opensearch_to() {
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
	if [ ! -f "${BACKUP_DIR}/opensearch-indexes.txt" ]; then
		echo "${BACKUP_DIR}/opensearch-indexes.txt not found, aborting"
		exit 2
	fi
      
    while read -r INDEX_NAME; do
		# Save the index mapping first, then save the data
    	gunzip "${BACKUP_DIR}/${INDEX_NAME}.mapping.json.gz"
    	elasticdump \
    		--input "${BACKUP_DIR}/${INDEX_NAME}.mapping.json" \
    		--output "http://localhost:9200/${INDEX_NAME}" \
    		--type mapping
    	gunzip  "${BACKUP_DIR}/${INDEX_NAME}.data.json.gz"
    	elasticdump \
    	    --intput "${BACKUP_DIR}/${INDEX_NAME}.data.json" \
    	    --output "http://localhost:9200/${INDEX_NAME}" \
    	    --type data
    done <"${BACKUP_DIR}/opensearch-indexes.txt"
}

function run_restore() {
	#
	# Sanity check our requiremented environment
	#
	SCRIPTNAME="$(readlink -f "$0")"
	DNAME="$(dirname "${SCRIPTNAME}")"
	cd "${DNAME}" || exit 1
	restore_opensearch_to "$1" "$2"
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
	run_restore "$1" "opensearch-dumps"
	;;
esac
