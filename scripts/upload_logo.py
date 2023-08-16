from invenio_communities.proxies import current_communities
from invenio_access.permissions import system_identity
import boto3, logging

boto3.set_stream_logger('', logging.DEBUG)

service = current_communities.service

with open('ca.png', "rb") as filestream:
	service.update_logo(system_identity, '669e5e57-7d9e-4d19-8ab5-9c6158562fb3', filestream)
