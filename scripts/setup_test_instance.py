import os
import requests
from caltechdata_api import get_metadata

token = os.environ["RDMTOK"]
host = "https://authors.caltechlibrary.dev"

# Create a caltechauthors community

community = {
    "access": {
        "visibility": "public",
        "member_policy": "open",
        "record_policy": "closed",
        "owned_by": [{'"user":2'}],
    },
    "slug": "caltechauthors",
    "metadata": {"title": "CaltechAUTHORS", "description": "Caltech Authors"},
}

response = requests.post(
    host + "/api/communities/",
    json=community,
    headers={"Authorization": f"Bearer {token}"},
)
if response.status_code != 201:
    print("Failed to create community")
    print(response.text)
    exit()

community_id = response.json()["id"]

print("Created community with id", community_id)

