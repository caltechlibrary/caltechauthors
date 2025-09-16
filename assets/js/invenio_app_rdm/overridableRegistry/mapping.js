// This file is part of InvenioRDM
// Copyright (C) 2023 CERN.
//
// Invenio App RDM is free software; you can redistribute it and/or modify it
// under the terms of the MIT License; see LICENSE file for more details.

import React, { Component } from "react";
import { List } from "semantic-ui-react";
import { i18next } from "@translations/invenio_rdm_records/i18next";

import _get from "lodash/get";
import _isEmpty from "lodash/isEmpty";


const SearchHelpLinks = () => {
  return (
    <List> <List.Item> <a href="https://caltechlibrary.github.io/irdm-queue-portal/">{i18next.t("Queue View")}</a> </List.Item> </List>
  )
}

export const overriddenComponents = {"InvenioCommunities.RequestSearch.SearchHelpLinks":SearchHelpLinks}; 
