# -*- coding: utf-8 -*-
#
# Copyright (C) 2023-2024 CERN.
# Copyright (C) 2024 Graz University of Technology.
#
# Invenio-App-RDM is free software; you can redistribute it and/or modify
# it under the terms of the MIT License; see LICENSE file for more details.

import sys

from click import secho
from flask import current_app
from invenio_access.permissions import system_identity
from invenio_communities.communities.records.api import Community
from invenio_communities.communities.records.systemfields.access import ReviewPolicyEnum
from invenio_db import db
from invenio_rdm_records.fixtures import PrioritizedVocabulariesFixtures
from invenio_rdm_records.proxies import current_rdm_records
from invenio_rdm_records.records.api import RDMDraft, RDMRecord


def execute_upgrade():

    def migrate_review_policy(community_record):
        if community_record.is_deleted:
            return

        community_record["access"].setdefault(
            "review_policy", ReviewPolicyEnum.CLOSED.value
        )


    secho("Starting data migration...", fg="green")

    # upgrading vocabularies
    pvf = PrioritizedVocabulariesFixtures(system_identity)
    pvf.load()

    # Migrating communities
    communities = Community.model_cls.query.all()

    for community_data in communities:
        community = Community(community_data.data, model=community_data)

        # production data could have problems without it
        if community:
            migrate_review_policy(community)
            community.commit()

    success = not errors

    if success:
        secho("Commiting to DB", nl=True)
        db.session.commit()
        secho(
            "Data migration completed, please rebuild the search indices now.",
            fg="green",
        )

    else:
        secho("Rollback", nl=True)
        db.session.rollback()
        secho(
            "Upgrade aborted due to the following errors:",
            fg="red",
            err=True,
        )

        for error in errors:
            secho(error, fg="red", err=True)

        msg = (
            "The changes have been rolled back. "
            "Please fix the above listed errors and try the upgrade again",
        )
        secho(msg, fg="yellow", err=True)

        sys.exit(1)


# if the script is executed on its own, perform the upgrade
if __name__ == "__main__":
    execute_upgrade()
