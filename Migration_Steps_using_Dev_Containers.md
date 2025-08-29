
# Steps to verify the migration processes using devcontainers and VS Code

1. Clone <https://github.com/caltechlibrary/caltechauthors> and checkout `v13` branch
2. Launch Drocker Desktop and VS Code
3. Follow [Setting_up_RDM_using_Dev_Containers.md](Setting_up_RDM_using_Dev_Containers.md) to setup the devcontainer for CaltechAUTHORS RDM repository.
4. Open a terminal in VS Code
5. Run [copy_rdm_production_db_records.bash](copy_rdm_production_db_records.bash) bash script from <https://github.com/caltechlibrary/rdm_migration>. 
6. Gunzip the SQL file for CaltechAUTHORS dump
7. Copy the SQL file into the docker container running PostgresSQL
8. Run a shell session in the Postgres docker container
9. Drop and recreate the caltechauthors database using `dropdb` and `createdb` cli
10. Once the database is empty start a `psql` connected to the caltechauthors db, use `\i` to load the SQL dump file
11. While still in psql shell use `\i` to run toms_sketch_migrate_11_to_13.sql and exit `psql` shell, exit docker container
12. Run `pipenv run scripts/migrate_11_0_to_12_0.py`
13. Run `pipenv run invenio alembic upgrade`
14. Rebuild the indexes, follow [building_indexes.md](building_indexes.md) first example
15. Run `invenio-cli run` and test


Starting with step #9, this is what I type at the terminal in VS Code

~~~shell
 docker container exec -it caltechauthors-db-1 /bin/bash
 # You should be at the container's bash prompt
 dropdb --username caltechauthors caltechauthors
 createdb --username caltechauthors caltechauthors
 exit
 # Copy the dumped Gunipped SQL file to the (NOTE the SQL file has a datestamp in it)
docker cp caltechauthors-dump_2025-08-28.sql caltechauthors-db-1:./
# Copy Tom's script to the container
docker cp scripts/tom_sketch_migrate_11_0_to_13_0.sql caltechauthors-db-1:./
# Run psql from inside the container
docker container exec -it caltechauthors-db-1 /usr/bin/psql --username caltechauthors caltechauthors
 # You should be the Postgres shell insite the Bash shell of the contiainer (\i takes a while to run)
 \i caltechauthors-dump_2025-08-28.sql
# Run Tom's SQL migration code
\i tom_sketch_migrate_11_0_to_13_0.sql 
exit
# Now we're back in the VS Code terminal, run the upgrade script.
pipenv run scripts/migrate_11_0_to_12_0.py # NOTE: This is failed, but in a previous run it worked. Note sure if it is required.
pipenv run invenio alembic upgrade
~~~

This takes you through step #13. Now we need to [rebuild the indexes](building_indexes.md). So type
the following commands in the VS Code terminal you're already running

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

You now maybe able to bring up RDM v13 to debug the SQL migration code.

~~~shell
include-cli run
~~~

Now you can debug the remaining mappings when the Web UI or API fails.
