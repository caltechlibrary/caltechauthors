
Database dump and restore
=========================

Two scripts are provided for dump and restore of an Invenio RDM stats.
They are based on the description of that at 

    <https://inveniordm.docs.cern.ch/develop/howtos/backup_search_indices/>

The dump and restore process uses [elasticdump](https://github.com/elasticsearch-dump/elasticsearch-dump) which is a NodeJS application installed with npm and n.

Two scripts are provided, `dump-opensearch-indexes.bash` and `restore-opensearch-indexes.bash`. The dump script will use `elasticdump` and save the indexes in gzip files in a "dump" directory.
The restore script will read the gzipped indexes the dump directory and restore all that it finds. If you want to restore a single index then the `elasticdump` tool can be used directly.

NOTE: Unlike the Postgres script our ports for Opensearch as mapped to the Host machine's localhost ports. E.g. you can interact with Opensearch REST API via port 9200. This is helpful since you don't want to mess with the NodeJS/npm setup inside the RDM containers!


## Doing the backup

If our repository is called "caltechauthors" then we would dump the indexes using the following command.

~~~shell
./dump-opensearch-indexes.bash caltechauthors
~~~

This will store the results of the dump in `opensearch-dumps` folder. Which will contain a bunch of files ending in `.gz`. Each one is an index retrieved using
`elasticdump`.

## Doing a restore

Locate (or restore) the `opensearch-dumps` directory. Vet the contents to make sure you only have the indexes you want restored.

~~~shell
./restore-opensearch-indexes.bash caltechauthors
~~~


## Requirements

- Bash (our dump/restore scripts use Bash)
- grep and cut (used to filter the setting results)
- jq (used to filter the settings results)
- curl (used to retrieve our list of indexes)
- elasticdump (a NodeJS application)

Bash, grep and cut come with the operating system. No instation is required for these.

### Installing jq

`jq` is available as a package on Debian/Ubuntu systems and can be installed via `sudo apt install jq`

### Installing curl

Curl is available as a package on Debian/Ubuntu systems and can be installed via `sudo apt install curl`

### Install elasticdump

This is how I was able to get NodeJS, NPM working to install `elasticdump`. The `n` command sets which NodeJS version is being run. It comes from NPM. In this case we want to the latest version.

1. Install NodeJS/NPM via Debian/Ubuntu packages
2. Use npm to install `n` to control which NodeJS is running in your shell
3. Install the latest of NodeJS using `n` to configure the environment correctly
4. Use `npm` to install `elasticdump`

NOTE: In this example I did this "globally" so it is available to all the uses of the host machine

~~~shell
sudo apt install nodejs npm
sudo npm install n -g
sudo n latest
sudo npm install elasticdump -g
~~~


[^1]: 
## Notes

Get a list of docker instances that are running to see where Opensearch can be reached.

~~~shell
sudo docker ps
~~~

Output is structed in the following columns.

~~~
CONTAINER ID   IMAGE                                COMMAND                  CREATED        STATUS                 PORTS                                                                                                                                                 NAMES
... data here ...
~~~

You're looking for an entry like 

~~~
ce7b386189fa   opensearchproject/opensearch:2.3.0   "./opensearch-docker…"   6 months ago   Up 4 hours             0.0.0.0:9200->9200/tcp, :::9200->9200/tcp, 9300/tcp, 0.0.0.0:9600->9600/tcp, :::9600->9600/tcp, 9650/tcp                                              caltechauthors_search_1
~~~

Assuming you see the the ported mapped to outside the container then we can work with that output on localhost host.

Get a list of available indexes.

~~~
curl http://localhost:9200/_settings
~~~

The indexes we're interested in have the repo name (e.g. "caltechauthors") and the word "stats" in the name.

~~~
curl http://localhost:9200/_settings | jq '.' \
  | grep '\-stats\-' | cut -d\" -f 2 | \
  grep -v provided_name | sort -u -r >stats-indexes.txt
~~~

Now we have a list of indexes that maybe of interesting to us.

From here we just need to know the repository name to know what needs to get backed up.

After reviewing indexes with Tom, we're going to backup any with the REPO_ID in the name.

## Identifying what to backup

Opensearch provides a "_settings" end point that shows how the Opensearch instance is configured. You can look for the REPO id in the settings object to get a list of indexes.

~~~shell
curl http://localhost:9200/_settings | jq '.' \
  | grep "${REPO_ID}-" | cut -d\" -f 2 | \
  grep -v provided_name | sort -u -r
~~~



