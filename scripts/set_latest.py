# Run with `pipenv run invenio shell fix_version.py`

from invenio_db import db
from invenio_accounts import current_accounts
from invenio_rdm_records.proxies import current_rdm_records_service as service

pids = ['e5gxk-vyg56']

for pid in pids:
    record = service.record_cls.pid.resolve(pid)
    print( record.versions.latest_id)
    record.versions.state().latest_id = record.id
    record.commit()
    db.session.commit()
    service.indexer.index(record)
    print(record.versions)
