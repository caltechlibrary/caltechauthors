#from celery import current_app 
#print(current_app.tasks.keys())
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service
from invenio_access.permissions import system_identity

service = get_record_service()

records = service.scan_expired_embargos(system_identity)
for record in records.hits:
    print(record)
