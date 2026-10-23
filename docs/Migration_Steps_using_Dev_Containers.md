
# Steps to verify the migration processes using devcontainers and VS Code

These instructions assume you have Git installed and can run the macOS Terminal program

## Getting the code

1. Clone repository, <https://github.com/caltechlibrary/caltechauthors>
2. Changing into the repository directory
3. Check out `v13` branch of code

~~~shell
git clone git@github.com:caltechlibrary/caltechauthors
cd caltechauthors
git checkout v13
~~~

## Setting up and migrating data

These instructions assume you are in the repository directory and have Docker Desktop Running. It assumes you have VS Code installed and available to run from the command line (Terminal).

1. From the Terminal, retrieve the current production data by running [copy_rdm_production_db_records.bash](copy_rdm_production_db_records.bash) bash script from <https://github.com/caltechlibrary/rdm_migration>. 
2. Open VS Code in the repository directory (e.g. `code .`)
3. You will be prompted to open the container, click to open and run the Docker containers
4. Open a VS Code terminal (App bar -> Terminal -> New Terminal)
5. In the terminal copy the SQL file into the docker container running PostgresSQL
  - This takes about 20 to 30 minutes on my machine
6. In the VS Code terminal copy Tom's script to the container
7. In the VS Code terminal run a shell session in the Postgres docker container
8. Drop and recreate the caltechauthors database using `dropdb` and `createdb` cli
9. Once the database is empty start a `psql` connected to the caltechauthors db, use `\i` to load the SQL dump file
10. Exit out of `psql`, exit out of the docker shell

This is what I type at the terminal in VS Code for setting up and migrating data

~~~shell
# Copy the dumped Gunzipped SQL file to the (NOTE the SQL file has a datestamp in it)
docker cp caltechauthors-dump.sql caltechauthors-db-1:./

# Copy Tom's script to the container
docker cp scripts/tom_sketch_migrate_11_0_to_13_0.sql caltechauthors-db-1:./

# Run shell inside Postgres container
docker container exec -it caltechauthors-db-1 /bin/bash

# You should be at the container's bash prompt
dropdb --username caltechauthors caltechauthors
createdb --username caltechauthors caltechauthors

# Run psql from inside the container
psql --username caltechauthors caltechauthors

# You should be the Postgres shell insite the Bash shell of the contiainer (\i takes a while to run)
\i caltechauthors-dump.sql

# Exit psql and docker shell
exit # psql
exit # docker sshell
~~~

## The upgrade process

1. Run `pipenv run invenio alembic upgrade` to upgade the database from the VS Code terminal
2. Run a shell session in the Postgres docker container
3. Once the docker shell run `psql`
4. Use `\i` to run toms_sketch_migrate_11_to_13.sql
5. Exit `psql` shell, exit docker container
6. Run `pipenv run scripts/migrate_11_0_to_12_0.py`
9. Rebuild the indexes, follow [building_indexes.md](building_indexes.md) first example

~~~shell
# Run alembic upgrade
pipenv run invenio alembic upgrade

# jump back into the docker shell running postgres
docker container exec -it caltechauthors-db-1 /bin/bash

# Run psql from inside the container
psql --username caltechauthors caltechauthors

# Run Tom's SQL migration code
\i tom_sketch_migrate_11_0_to_13_0.sql 

# Exit psql and docker shell
exit # psql
exit # docker shell

# Now we're back in the VS Code terminal, run the upgrade script.
pipenv run invenio shell scripts/migrate_11_0_to_12_0.py
~~~

## Rebuild indexes

This takes you through step #19. Now we need to [rebuild the indexes](building_indexes.md). So type
the following commands in the VS Code terminal you're already running

~~~shell
pipenv run invenio index destroy --yes-i-know
search_prefix=$(pipenv run invenio shell -c "print(app.config['SEARCH_INDEX_PREFIX'])")
pipenv run invenio index delete --force --yes-i-know "${search_prefix}rdmrecords-records-record-*-percolators"
pipenv run invenio index init
# if you have records custom fields
pipenv run invenio rdm-records custom-fields init
pipenv run invenio rdm rebuild-all-indices
~~~

## Launch and test RDM instance

You now maybe able to bring up RDM v13 to debug the SQL migration code.

~~~shell
invenio-cli run
~~~

Now you can debug the remaining mappings when the Web UI or API fails.

RDM should be available at <https://localhost:5000>
OpenSearch Admin Panel at <http://localhost:5601>
