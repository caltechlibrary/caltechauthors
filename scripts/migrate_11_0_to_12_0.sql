-- Update parent schema
update
  rdm_parents_metadata
set
  json = jsonb_set(
    json,
    '{schema}',
    '"local://records/parent-v3.0.0.json"'
  )
where
  json->>'schema' != 'local://records/parent-v3.0.0.json';

UPDATE rdm_parents_metadata
SET json = jsonb_set(
  json,
  '{access,owned_by}',
  jsonb_build_object('user', json->'access'->'owned_by'->0->'user')
)
WHERE json->'access'->'owned_by'->0->'user' is not null;

update
  rdm_parents_metadata
set
  json = jsonb_set(
    json,
    '{pids}',
    '"{}"'
  )

-- Update record schema
update
  rdm_records_metadata
set
  json = jsonb_set(
    json,
    '{schema}',
    '"local://records/record-v6.0.0.json"'
  )
where
  json->>'schema' != 'local://records/record-v6.0.0.json';

update
  rdm_records_metadata
set
  json = jsonb_set(
    json,
    '{media_files,enabled}',
    '"False"'
  )

-- Update drafts schema
update
  rdm_drafts_metadata
set
  json = jsonb_set(
    json,
    '{schema}',
    '"local://records/record-v6.0.0.json"'
  )
where
  json->>'schema' != 'local://records/record-v6.0.0.json';

update
  rdm_drafts_metadata
set
  json = jsonb_set(
    json,
    '{media_files,enabled}',
    '"False"'
  )
