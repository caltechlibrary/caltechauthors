from dotenv import load_dotenv

# Load .env before gunicorn imports the WSGI app so all INVENIO_* vars are in
# os.environ when the Flask factory runs. The instance path defaults to
# .venv/var/instance/; invenio.cfg is symlinked there by invenio-cli install.
load_dotenv()

bind = "127.0.0.1:5000"
workers = 2
timeout = 60
loglevel = "info"
errorlog = "/tmp/gunicorn-error.log"
accesslog = "-"
