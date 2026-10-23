
The is what I run to do a clean indexing of a new RDM instance.

~~~shell
pipenv run invenio index destroy --yes-i-know
search_prefix=$(pipenv run invenio shell -c "print(app.config['SEARCH_INDEX_PREFIX'])")
pipenv run invenio index delete --force --yes-i-know "${search_prefix}rdmrecords-records-record-*-percolators"
pipenv run invenio index init
# if you have records custom fields
pipenv run invenio rdm-records custom-fields init
# if you have communities custom fields
##pipenv run invenio communities custom-fields init ## skipped in devcontainer test
pipenv run invenio rdm rebuild-all-indices
~~~

This is what I do to refresh the indexes in an existing RDM instance.

~~~shell
pipenv run invenio index destroy --yes-i-know
pipenv run invenio index init
pipenv run invenio rdm-records custom-fields init
pipenv run invenio rdm rebuild-all-indices
~~~

Opensearch Admin Panel

- Container URL mapped to: <http://localhost:5601>

The following is based on documentation at <https://inveniordm.docs.cern.ch/releases/v13/upgrade-v13.0/#rebuild-search-indices>.

