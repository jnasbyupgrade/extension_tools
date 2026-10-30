\set ECHO none
\i test/pgxntool/setup.sql

/*
 * A role that can't use extension_drop's registration table must get an
 * actionable insufficient_privilege error, not a raw "permission denied for
 * table", whenever a drop includes an extension -- registered or not -- via
 * any of the three commands the trigger fires for.
 */
SELECT plan(
  2 -- Setup: role, schema with extension
  + 1 -- DROP SCHEMA CASCADE without USAGE on extension_drop's schema
  + 3 -- DETAIL and HINT
  + 2 -- USAGE on extension_drop's schema, but no table privileges
  + 2 -- DETAIL
  + 2 -- Unregistered extension
  + 1 -- DROP OWNED BY
  + 2 -- Cleanup
  + 1 -- Recreate the registered extension
  + 2 -- SELECT but not DELETE
  + 2 -- SELECT and DELETE, registered SQL fails with its own privilege error
  + 3 -- SELECT and DELETE, registered SQL succeeds
  + 1 -- Registration removed
  + 3 -- The same privileges held through a group role
  + 4 -- DROP EXTENSION by a role that was a superuser when it created it
  + 2 -- Cleanup
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide version-specific NOTICE/WARNING text from the drops
SET client_min_messages = ERROR;

\set MSG 'permission denied to drop extension(s) extension_drop_test'

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_plain'
  , 'Create non-superuser role'
);
-- Created as superuser, so the role only owns the schema
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain;
    CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_plain_schema$$
  , 'Create schema owned by role containing a registered extension'
);

SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP SCHEMA CASCADE without USAGE on extension_drop''s schema'
);

-- The error text reaches the caller as DETAIL and HINT; stash them in GUCs to compare
SELECT lives_ok(
  $q$DO $$
  DECLARE d text; h text;
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    DROP SCHEMA extension_drop_test_plain_schema CASCADE;
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.detail', d, false), set_config('extension_drop_test.hint', h, false);
  END $$$q$
  , 'Capture DETAIL and HINT'
);
/*
 * Without USAGE the table can't be found by name ("does not exist"); in existing mode the schema is
 * public, which everyone can use, so it is "permission denied" instead.
 */
SELECT matches(
  current_setting('extension_drop_test.detail')
  , format(
      '^extension_drop must read and delete its registration in %s\.extension_drop__commands: (relation "extension_drop__commands" does not exist|permission denied for table extension_drop__commands)$'
      , regexp_replace(quote_ident(:'extension_drop_schema'), '([^a-zA-Z0-9_])', '\\\1', 'g'))
  , 'DETAIL'
);
SELECT is(
  current_setting('extension_drop_test.hint')
  , format(
      'Run the drop as role %1$I or a superuser, or grant USAGE on schema %2$I and SELECT, DELETE on %2$I.extension_drop__commands to the current role.'
      , current_user, :'extension_drop_schema')
  , 'HINT'
);

SELECT lives_ok(
  format('GRANT USAGE ON SCHEMA %I TO extension_drop_test_plain', :'extension_drop_schema')
  , 'Grant USAGE on extension_drop''s schema'
);
SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP SCHEMA CASCADE with USAGE but no table privileges'
);
SELECT lives_ok(
  $q$DO $$
  DECLARE d text;
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    DROP SCHEMA extension_drop_test_plain_schema CASCADE;
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
    PERFORM set_config('extension_drop_test.detail', d, false);
  END $$$q$
  , 'Capture DETAIL'
);
SELECT is(
  current_setting('extension_drop_test.detail')
  , format(
      'extension_drop must read and delete its registration in %I.extension_drop__commands: permission denied for table extension_drop__commands'
      , :'extension_drop_schema')
  , 'DETAIL includes the original error'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__remove('extension_drop_test')$$, :'extension_drop_schema')
  , 'Unregister the extension'
);
SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP SCHEMA CASCADE of an unregistered extension'
);

SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP OWNED BY extension_drop_test_plain CASCADE; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP OWNED BY'
);

SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , 'Superuser drop schema'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);

SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain;
    CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_plain_schema$$
  , 'Recreate the registered extension'
);

-- SELECT alone is not enough: the trigger deletes the registration
SELECT lives_ok(
  format('GRANT SELECT ON %I.extension_drop__commands TO extension_drop_test_plain', :'extension_drop_schema')
  , 'Grant SELECT'
);
SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP SCHEMA CASCADE with SELECT but not DELETE'
);

-- A privilege error from the registered SQL itself is not extension_drop's to translate
SELECT lives_ok(
  format($$GRANT DELETE ON %1$I.extension_drop__commands TO extension_drop_test_plain;
           SELECT %1$I.extension_drop__update('extension_drop_test', 'CREATE ROLE extension_drop_test_never')$$
    , :'extension_drop_schema')
  , 'Grant DELETE, register SQL that needs CREATEROLE'
);
SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; END $$$q$
  , '42501'
  , 'permission denied to create role'
  , 'Registered SQL''s own privilege error surfaces unchanged'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Register harmless SQL'
);
SELECT lives_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; RESET ROLE; END $$$q$
  , 'DROP SCHEMA CASCADE with the privileges the HINT names'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);
SELECT is_empty(
  format($$SELECT 1 FROM %I.extension_drop__commands WHERE extension_name = 'extension_drop_test'$$, :'extension_drop_schema')
  , 'Registration removed'
);

-- Privileges held only through a group role the caller is a member of
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain;
    CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_plain_schema$$
  , 'Recreate the registered extension'
);
SELECT lives_ok(
  format(
    $$SELECT %1$I.extension_drop__update('extension_drop_test', 'SELECT 1');
      REVOKE SELECT, DELETE ON %1$I.extension_drop__commands FROM extension_drop_test_plain;
      REVOKE USAGE ON SCHEMA %1$I FROM extension_drop_test_plain;
      CREATE ROLE extension_drop_test_group;
      GRANT USAGE ON SCHEMA %1$I TO extension_drop_test_group;
      GRANT SELECT, DELETE ON %1$I.extension_drop__commands TO extension_drop_test_group;
      GRANT extension_drop_test_group TO extension_drop_test_plain$$
    , :'extension_drop_schema')
  , 'Move the grants from the role to a group it belongs to'
);
SELECT lives_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; RESET ROLE; END $$$q$
  , 'DROP SCHEMA CASCADE with the privileges held through a group role'
);

-- ALTER EXTENSION can't change the owner, so create it as a role that is then demoted
SELECT lives_ok(
  'CREATE ROLE extension_drop_test_owner SUPERUSER'
  , 'Create role'
);
SELECT lives_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_owner; CREATE EXTENSION extension_drop_test; RESET ROLE; END $$$q$
  , 'Create test extension as role'
);
SELECT lives_ok(
  'ALTER ROLE extension_drop_test_owner NOSUPERUSER'
  , 'Demote role'
);
SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_owner; DROP EXTENSION extension_drop_test; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP EXTENSION by the extension''s non-superuser owner'
);

SELECT lives_ok(
  'DROP EXTENSION extension_drop_test'
  , 'Superuser drop extension'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
