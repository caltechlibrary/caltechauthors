import click, os

from flask.cli import with_appcontext
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service
from invenio_pidstore.models import PersistentIdentifier

@click.command('delete_pid')
@click.argument('pid', type=str)
@with_appcontext
def get_pid(pid):
    """Get pid"""
    service = get_record_service()
    provider = service.pids.pid_manager._get_provider("doi", "external")
    pid_uuid = provider.get(pid_value=pid).object_uuid
    query = PersistentIdentifier.query.filter_by(
            object_uuid=pid_uuid,
            pid_type="recid",
        )
    pid_value = query.first().pid_value

    print(pid_value)


if __name__=="__main__":
    get_pid()
