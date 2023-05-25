from flask_security.utils import hash_password
from invenio_accounts.proxies import current_datastore
from invenio_db import db

user = current_datastore.get_user("user@caltech.edu")
user.password = hash_password("password")
current_datastore.activate_user(user)
db.session.commit()
