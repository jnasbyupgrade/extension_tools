\set ECHO none
\i test/pgxntool/setup.sql

/*
 * DROP SCHEMA ... CASCADE can drop an extension; its registered command must
 * run and the registration must go away, or the stale row makes every later
 * DROP EXTENSION fail.
 */
SELECT plan(
  0

  + 1 -- Insert into test table

  + 1 -- Create schema
  + 1 -- Create test extension in it
  + 1 -- Verify extension_drop__get()
  + 1 -- Drop schema cascade
  + 1 -- Verify test extension is gone
  + 1 -- Verify test table is empty
  + 1 -- Verify no stale registration

  + 4 -- Create and drop test extension again (test/helpers/test_ext__create_drop.sql)

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide the version-specific "drop cascades to" NOTICE
SET client_min_messages = WARNING;

\i test/helpers/test_ext__insert.sql

SELECT lives_ok(
  'CREATE SCHEMA extension_drop_test_schema'
  , 'Create schema'
);
SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_schema'
  , 'Create test extension in schema'
);
SELECT bag_eq(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , $$SELECT 'extension_drop_test'::name, 'DELETE FROM extension_drop_test_table'::text$$
  , 'Verify extension_drop__get()'
);

SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_schema CASCADE'
  , 'Drop schema cascade'
);
SELECT hasnt_extension('extension_drop_test', 'Test extension does not exist');
SELECT is_empty(
  $$SELECT * FROM $$ || :'TT'
  , :'TT' || ' is empty'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);

\i test/helpers/test_ext__create_drop.sql

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
