"""Additional views."""

from flask import Blueprint
from invenio_pages.views import create_page_view

#
# Static pages
#
# /help, /policies and friends are rows in invenio-pages' pages_page table,
# edited through /administration/pages. Their content is intact -- what was
# missing is the routing.
#
# invenio-pages registers those URLs lazily, out of its own 404 handler
# (invenio_pages.views.handle_not_found, installed by
# InvenioPages.wrap_errorhandler during init_app). That hook does not survive
# startup: invenio-theme's init_app runs later and calls
# app.register_error_handler(404, page_not_found), which replaces
# app.error_handler_spec[None][404][NotFound] outright rather than wrapping
# it, so invenio-pages never gets a chance to look a page up and never adds
# the rule.
#
# Verified live on caltechauthors-v13, 2026-09-10: invenio-pages is loaded,
# all five page rows are present with content, the app-level 404 handler is
# invenio_theme.views.page_not_found, and app.url_map carries RDM's built-in
# /help/search, /help/statistics and /help/versioning but no /help and no
# /policies. All five URLs returned 404 from the UI app directly, with nginx
# never involved.
#
# Registering the rules explicitly sidesteps the ordering question instead of
# betting on it, and is what invenio-pages' own create_page_view docstring
# recommends.
#
# Keep this tuple in step with the pages_page table. A URL listed here with no
# matching row 404s from render_page, and a row whose URL is not listed stays
# unreachable.
#
# /help/statistics is deliberately absent. RDM owns that URL through its own
# route, and the Caltech version of the page is a template override at
# templates/semantic-ui/invenio_app_rdm/help/statistics.en.html. There is no
# row for it, so listing it here would shadow a working route with a 404.
STATIC_PAGE_URLS = (
    "/about",
    "/help",
    "/metadata_searching",
    "/policies",
    "/year",
)


#
# Registration
#
def create_blueprint(app):
    """Register blueprint routes on app."""
    blueprint = Blueprint(
        "caltechauthors",
        __name__,
        template_folder="./templates",
    )

    # Add URL rules
    for url in STATIC_PAGE_URLS:
        # create_page_view() names every view it returns "_view", so each rule
        # needs its own explicit endpoint -- left to Flask's default they would
        # all derive the same one and the second registration would raise.
        blueprint.add_url_rule(
            url,
            endpoint="static_page{}".format(url.replace("/", "_")),
            view_func=create_page_view(url),
        )

    return blueprint
