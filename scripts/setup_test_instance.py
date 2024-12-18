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


response = requests.post(
    host + "/api/communities",
    json=community,
    headers={"Authorization": f"Bearer {token}"},
)
if response.status_code != 201:
    print("Failed to create community")
    print(response.text)
    exit()

community_id = response.json()["id"]

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
    response = caltechdata_write(
        metadata,
        token,
        authors=True,
        production=False,
        community=community_id,
        publish=True,
    )
    print(response)
