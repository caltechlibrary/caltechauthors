import click, os

from flask.cli import with_appcontext
from invenio_db import db
from invenio_files_rest.models import ObjectVersion
from invenio_rdm_records.proxies import current_rdm_records_service as service
from invenio_access.permissions import any_user, system_identity
from invenio_access.utils import get_identity
from invenio_accounts import current_accounts
from werkzeug.utils import import_string


def get_or_import(value, default=None):
    """Try an import if value is an endpoint string, or return value itself."""
    if isinstance(value, str):
        return import_string(value)
    elif value:
        return value

    return default


def get_user_by_identifier(id_or_email):
    """Get the user specified via email or ID."""
    if id_or_email is not None:
        # note: this seems like the canonical way to go
        #       'id_or_email' can be either an integer (id) or email address
        u = current_accounts.datastore.get_user(id_or_email)
        if u is not None:
            return u
        else:
            raise LookupError("user not found: %s" % id_or_email)

    raise ValueError("id_or_email cannot be None")


def get_identity_for_user(user):
    """Get the Identity for the user specified via email or ID."""
    if user is not None:
        found_user = get_user_by_identifier(user)
        identity = get_identity(found_user)
        identity.provides.add(any_user)
        return identity

    return system_identity

@click.command('delete_file')
@click.argument('recid', type=str)
@click.argument('filename', type=str)
@click.argument('user', type=int)
@with_appcontext
def delete_file(recid, filename, user):
    """Delete a file in a published record."""
    identity = get_identity_for_user(user)
    record = service.read(id_=recid,identity=identity)._record
    bucket = record.files.bucket
    key = filename

    obj = ObjectVersion.get(bucket, key)

    click.echo(u'Will delete the following file:\n')
    click.echo(click.style(
        u'  key: "{key}"\n'
        u'  bucket: {bucket}\n'
        u''.format(
            key=key,
            bucket=bucket.id),
        fg='green'))
    click.echo(u'from record:\n')
    click.echo(click.style(
        u'  Title: "{title}"\n'
        u'  RECID: {recid}\n'
        u'  UUID: {uuid}\n'
        u''.format(
            recid=record['id'],
            title=record['metadata']['title'],
            uuid=record.id),
        fg='green'))

    if click.confirm(u'Continue?'):
        bucket.locked = False
        record.files.delete(key)
        bucket.locked = True

        record.commit()
        db.session.commit()
        click.echo(click.style(u'File deletion successful.', fg='green'))
    else:
        click.echo(click.style(u'File deletion aborted.', fg='green'))

if __name__=="__main__":
    delete_file()
