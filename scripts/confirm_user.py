import click
from flask_security.confirmable import confirm_user
from invenio_accounts.proxies import current_datastore
from invenio_db import db
from invenio_users_resources.services.users.tasks import reindex_user

@click.group(invoke_without_command=True)
@click.argument('user_email', type=str)
def main(user_email):
    user = current_datastore.get_user(user_email)
    confirm_user(user)
    db.session.commit()
    reindex_user(user.id)

if __name__=="__main__":
    main()
