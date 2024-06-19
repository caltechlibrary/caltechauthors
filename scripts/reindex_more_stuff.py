from invenio_access.permissions import system_identity
from invenio_communities.proxies import current_communities
from invenio_records_resources.proxies import current_service_registry
from invenio_requests.proxies import current_events_service, current_requests_service
from invenio_accounts.models import User

# reindex users
users_service = current_service_registry.get("users")
for user in User.query.all():
    user_agg = users_service.record_cls.from_user(user)
    users_service.indexer.index(user_agg)

# reindex members
members_service = current_communities.service.members
for rec_meta in members_service.record_cls.model_cls.query.all():
    rec = members_service.record_cls(rec_meta.data, model=rec_meta)
    if not rec.is_deleted:
        members_service.indexer.index(rec)

# reindex requests
for req_meta in current_requests_service.record_cls.model_cls.query.all():
    request = current_requests_service.record_cls(req_meta.data, model=req_meta)
    if not request.is_deleted:
        current_requests_service.indexer.index(request)

# reindex requests events
for event_meta in current_events_service.record_cls.model_cls.query.all():
    event = current_events_service.record_cls(event_meta.data, model=event_meta)
    current_events_service.indexer.index(event)
