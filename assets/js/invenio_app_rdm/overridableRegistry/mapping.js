// This file is part of InvenioRDM
// Copyright (C) 2023 CERN.
//
// Invenio App RDM is free software; you can redistribute it and/or modify it
// under the terms of the MIT License; see LICENSE file for more details.

import React, { Component } from "react";
import PropTypes from "prop-types";

import { FieldLabel, TextField } from "react-invenio-forms";
import { i18next } from "@translations/invenio_rdm_records/i18next";

export class PublisherField extends Component {
  render() {
    const { fieldPath, label, labelIcon, placeholder } = this.props;

    return (
      <TextField
        fieldPath={fieldPath}
        helpText={i18next.t(
          "If you're submitting a published journal article, ignore this field and use the 'Journal name' field in the 'Caltech Custom Metadata' section. If you're creating a DOI, this field is important as it shows up in the citation."
        )}
        label={<FieldLabel htmlFor={fieldPath} icon={labelIcon} label={label} />}
        placeholder={placeholder}
      />
    );
  }
}

PublisherField.propTypes = {
  fieldPath: PropTypes.string.isRequired,
  label: PropTypes.string,
  labelIcon: PropTypes.string,
  placeholder: PropTypes.string,
};

PublisherField.defaultProps = {
  label: i18next.t("Publisher"),
  labelIcon: "building outline",
  placeholder: i18next.t("Publisher"),
};

export const overriddenComponents = {"InvenioAppRdm.Deposit.PublisherField.container":PublisherField,}; 
