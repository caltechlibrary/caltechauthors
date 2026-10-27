---
title: Setting up RDM Using Dev Containers and VS Code
---

# Setting up RDM Using Dev Containers and VS Code

## Requirements (macOS)

- VS Code
- Docker Desktop
- Git

## Steps

Getting ready:

1. Clone <https://github.com/caltechlibrary/caltechauthors> (example `git clone git@github.com:caltechlibrary/caltechauthors $HOME/Sites/caltechauthors`)
2. Change into the caltechauthors folder (`cd $HOME/Sites/caltechauthors`)
3. Check out the branch with the dev container (e.g. "v13", `git checkout v13`)
4. Launch Docker Desktop
5. Launch VS Code (example Applications (folder) -> (double click on) Visual Studio Code (icon))

Bring up RDM:

1. In VS Code, File -> Open Folder (navigate into the cloned repository folder and click open)
2. You should see a "Open Dev Container" click the blue button (NOTE: if the button says, "Reopen Dev Container", you need to follow the rebuild instructions below to get a clean copy of the repo)
3. You should eventually see "Done. Press any key to close the terminal." in the terminal window building/rebuilding your dev container
4. Open a new terminal window in VS Code, menu "Terminal" -> "New Terminal" (You should see a prompt like, `vscode ➜ /workspaces/caltechauthors (v13) $ `)
5. Type the following into your new Terminal session, `invenio-cli services setup -N`
  a. It'll take a while (for me greater than five minutes)
  b. Ignore the lower right dialog about opening the port in your browser or editor, it is NOT ready yet and links to the wrong URL
  c. You'll be ready for the next step when you see "Successfully setup all services."
6. In the terminal type `invenio-cli services status`
  a. You should see that redis, postgresql and search are running
7. Load affiliations and funders
  a. run `pipenv run invenio vocabularies update --vocabulary affiliations --origin ror-http
  b. run `pipenv run invenio vocabularies update --vocabulary funders --origin ror-http`
8. In the terminal type `invenio-cli run`
  a. This will take a while (many minutes), get some coffee
  b. As always ignore the "Open in Browser" button, the URL is wrong as well as premature
  c. After waiting for RDM to sort itself the log messages in the Terminal console will ebb
9. Copy a .env file with secrets (mostly email credentials)
10. Set up storage with `pipenv run invenio files location s3-default s3://caltechauthors-test --default`
11. Open the following URL in your web browser <https://127.0.0.1:5000/>
  a. Note the https
  b. Click through the scary warning about the SSL certificate
12. Reset your password using the "Forgot Password" link on the login page
13. Get an InvenioRDM token for your account
14. Set as `export RDMTOK=<your token>` in the terminal window
15. Set up test records with `python scripts/setup_test_instance.py`

## Shutdown your development setup

If you are going to work on this again you can shut everything down using VS Code menu, File -> Close Remote Connection. If the directory is still showing go to File -> Close Folder. Then in the Docker Desktop make sure the container is really stopped (should be but sometimes ...).

## Starting back up

This is the easy bit if you're patient.  

1. Launch Docker Desktop
2. Launch VS Code
3. VS Code Menu: File -> Open Folder (navigate to the repository and open)
4. Click on "Reopen Container" blue button in the lower right dialog
5. In the lower left status bar is a blue element labeled "Dev Container: CaltechAUTHORS Development", click on it
6. In the search UI click on "Reopen Container", you should see a Terminal open and ready to go after connecting.
7. Check to make sure the services are up and running, `invenio-cli services status`
8. Run the RDM, `invenio-cli run`, wait for everything to come
9. Point your browser at <https://127.0.0.1:5000> (NOTE: use "https" not "http" suggested in the ports links)

### NOTES ON "Reopen Dev Container"

If you get this dialog (instead of "Open Dev Containers") and you want to start clean install then you need to "rebuild" the development container.

1. In the lower left of the editor you hopefully see a "Dev Container: CaltechAUTHORS Development..." status in blue, click on it.
2. This will open up the search box at the top of the editor (horrible UI I know), select "rebuild container" from the list that magically is there.
  a. Rebuilding is going to take a while
  b. You should see "Configuring Dev Container (show log)" in the notification popup (lower right) or status bar (bottom).
  c. If you are interested in monitoring the progress click on the "Configuring Dev Container (show log)" popup



