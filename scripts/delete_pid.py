import click, os

from flask.cli import with_appcontext
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_utilities_tuw.utils import get_identity_for_user, get_record_service

@click.command('delete_pid')
@click.argument('pid', type=str)
@with_appcontext
def delete_pid(pid):
    """Delete pid"""
    service = get_record_service()
    provider = service.pids.pid_manager._get_provider("doi", "external")
    pid = provider.get(pid_value=pid)
    print(pid)
    pid.delete()
    print(pid)
    print('Deleted')
    db.session.delete(pid)
    db.session.commit()

if __name__=="__main__":
    delete_pid()
