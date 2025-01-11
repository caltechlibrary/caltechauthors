
from flask import request, g
from flask_login import current_user
from flask_principal import RoleNeed

from invenio_requests.proxies import current_requests_service
from invenio_access.permissions import system_identity

from invenio_requests.views.decorators import pass_request


def has_admin_permissions():
    return RoleNeed('admin') in g.identity.provides

def is_record_owner(record_user_id):
    return record_user_id ==  g.identity.id

def has_permissions(record_user_id):
    return is_record_owner(record_user_id) or has_admin_permissions()

@pass_request(expand=True)
def  get_expanded_data(request_pid_value, **kwargs):

    request_data  = kwargs['request']

    expanded_request = request_data.to_dict()

    return expanded_request

def get_comments_data(record_id):

    check_permission = True

    search_params = { "q": f"topic.record:{record_id} AND is_closed:true" }
    result = current_requests_service.search(
                          identity=system_identity,
                          params=search_params
                         )
    requests =  result.to_dict()['hits']

    if requests['total'] > 0:
        record_user_id = requests['hits'][0]['created_by']['user']
        if (not check_permission) or has_permissions(record_user_id):
            request_id = requests['hits'][0]['id']
            expanded_data  = get_expanded_data(request_pid_value=request_id)
            return {'request': expanded_data }
        else:
            return None
    else:
        return None


def register_filters(app):
    app.jinja_env.filters['comments_data'] =  get_comments_data
