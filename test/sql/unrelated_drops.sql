\set ECHO none
\i test/pgxntool/setup.sql

/*
 * DROP SCHEMA and DROP OWNED fire extension_drop's event trigger, so drops
 * that involve no extension must not depend on the caller's privileges or on
 * the state of extension_drop__commands.
 */
SELECT plan(
  0

  + 1 -- Create non-superuser role
  + 1 -- Grant it CREATE on the database
  + 1 -- Non-superuser DROP SCHEMA CASCADE
  + 1 -- Non-superuser DROP OWNED BY

  + 1 -- Insert stale registration
  + 1 -- Stale registration is present
  + 1 -- Superuser DROP SCHEMA with stale registration

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide version- and database-specific NOTICE/WARNING text from the drops
SET client_min_messages = ERROR;

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_plain'
  , 'Create non-superuser role'
);
SELECT lives_ok(
  format('GRANT CREATE ON DATABASE %I TO extension_drop_test_plain', current_database())
  , 'Grant CREATE on database'
);

SELECT lives_ok(
  $q$DO $$ BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    CREATE SCHEMA extension_drop_test_plain_schema;
    CREATE TABLE extension_drop_test_plain_schema.t(i int);
    DROP SCHEMA extension_drop_test_plain_schema CASCADE;
    RESET ROLE;
  END $$$q$
  , 'Non-superuser DROP SCHEMA CASCADE'
);
SELECT lives_ok(
  $q$DO $$ BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    CREATE SCHEMA extension_drop_test_plain_schema;
    CREATE TABLE extension_drop_test_plain_schema.t(i int);
    DROP OWNED BY extension_drop_test_plain;
    RESET ROLE;
  END $$$q$
  , 'Non-superuser DROP OWNED BY'
);

SELECT lives_ok(
  format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Insert stale registration'
);
SELECT results_eq(
  format($$SELECT %I.extension_drop__sanity_check()$$, :'extension_drop_schema')
  , $$SELECT '{extension_drop_test_stale}'::name[]$$
  , 'Stale registration is present'
);
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_su_schema; DROP SCHEMA extension_drop_test_su_schema$$
  , 'Superuser DROP SCHEMA with stale registration'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
