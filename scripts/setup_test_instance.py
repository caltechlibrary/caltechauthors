import os, json
import requests
from caltechdata_api import get_metadata, caltechdata_write

token = os.environ["RDMTOK"]
host = "https://authors.caltechlibrary.dev"

# Create a caltechauthors community

community = {
    "access": {
        "visibility": "public",
        "member_policy": "open",
        "record_submission_policy": "closed",
    },
    "slug": "caltechauthors",
    "metadata": {"title": "CaltechAUTHORS", "description": "Caltech Authors"},
}


#response = requests.post(
#    host + "/api/communities",
#    json=community,
#    headers={"Authorization": f"Bearer {token}"},
#)
#if response.status_code != 201:
#    print("Failed to create community")
#    print(response.text)
#    exit()

#community_id = response.json()["id"]
community_id = '524939f5-3917-42f1-baaa-cf2e044e8204'

print("Created community with id", community_id)

records = [
    "wa49w-k3z81",
    "5c8j5-dy388",
    "png74-p3m63",
    "94yb4-yq016",
    "3xm22-rgm85",
]

for record in records:
    metadata = get_metadata(record, authors=True)
    metadata["pids"].pop("oai")
    files = metadata.pop("files")
    file_names = []
    for file in files["entries"].keys():
        file_names.append(file)
        with open(file, "wb") as f:
            r = requests.get(
                f"https://authors.library.caltech.edu/records/{record}/files/{file}?download=1"
            )
            f.write(r.content)
    response = caltechdata_write(
        metadata,
        token,
        authors=True,
        production=False,
        community=community_id,
        publish=True,
        files=file_names,
    )
    print(response)
