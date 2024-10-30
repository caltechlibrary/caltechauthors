# Run with `pipenv run invenio shell fix_version.py`

from invenio_db import db
from invenio_accounts import current_accounts
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service


pids = ['g5k1d-1rp46']

u = get_identity_for_user(2)
service = get_record_service()

for pid in pids:
    record = service.record_cls.pid.resolve(pid)
    print(record.versions)
    record.versions._record.model.index = 4
    record.commit()
    db.session.commit()
    service.indexer.index(record)
    print(record.versions)
