\set ECHO none
\i test/pgxntool/setup.sql

/*
 * extension_drop calls extension_drop__claim() as whichever role drops an extension, so PUBLIC
 * must keep USAGE on its schema: install and update refuse without it, REVOKE / DROP OWNED that would
 * remove it are rolled back (ddl_command_end), and every REVOKE / DROP OWNED is refused up front while
 * PUBLIC already lacks it (ddl_command_start).
 */
SELECT plan(
  1 -- setup
  + 8 -- REVOKE and DROP OWNED rejected, state unchanged
  + 5 -- guard bypassed: REVOKE and DROP OWNED refused up front, recovery
  + 7 -- reinstall; install and update refused without PUBLIC USAGE
  + 11 -- restore mode: install queues the grant for COMMIT
  + 6 -- the guard accepts a queued grant
  + 3 -- error mode; invalid value
  + 7 -- restore mode: update
  + 6 -- restore mode: install into public

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Primary messages always double-quote the name; the HINT's GRANT quotes it only when needed
SELECT quote_ident(:'extension_drop_schema') AS qschema
  , '"' || replace(:'extension_drop_schema', '"', '""') || '"' AS dqschema
\gset
SELECT format('cannot remove USAGE on schema %s from PUBLIC', :'dqschema') AS removal_msg
  , format('PUBLIC lacks USAGE on schema %s', :'dqschema') AS lacks_msg
  , format('Run GRANT USAGE ON SCHEMA %s TO PUBLIC.', :'qschema') AS lacks_hint
\gset

-- The query returning the HINT and DETAIL of the USAGE error (55000) that sql raises
SELECT $$SELECT hint, detail FROM pg_temp.xd_capture(%L, '55000')$$ AS capture_query
  , 'When restoring a dump, set extension_drop.missing_public_usage to ''grant'' instead.' AS restore_hint
\gset
SELECT 'Run GRANT USAGE ON SCHEMA "xd no usage" TO PUBLIC (creating the schema first if needed), then retry. ' || :'restore_hint' AS install_hint
\gset

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_grantor'
  , 'Create role'
);

SELECT throws_ok(
  format('REVOKE USAGE ON SCHEMA %I FROM PUBLIC', :'extension_drop_schema')
  , '55000'
  , :'removal_msg'
  , 'REVOKE USAGE ON SCHEMA ... FROM PUBLIC is rejected'
);
-- Not schema_privs_are(): it asserts PUBLIC's exact privilege set, and in existing mode PUBLIC may also have CREATE
SELECT is(
  has_schema_privilege('public', :'extension_drop_schema', 'USAGE')
  , true
  , 'PUBLIC still has USAGE'
);

SELECT throws_ok(
  format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', :'extension_drop_schema')
  , '55000'
  , :'removal_msg'
  , 'REVOKE ALL ON SCHEMA ... FROM PUBLIC is rejected'
);
-- No GRANT HINT: the command was prevented, nothing to fix
SELECT results_eq(
  format(:'capture_query', format('REVOKE USAGE ON SCHEMA %I FROM PUBLIC', :'extension_drop_schema'))
  , $$VALUES ('', 'extension_drop requires PUBLIC to have USAGE on the schema it is installed in. DDL command: REVOKE')$$
  , 'HINT is empty and DETAIL explains the requirement and names the command'
);

-- Only PUBLIC's USAGE matters
SELECT lives_ok(
  format('GRANT USAGE ON SCHEMA %1$I TO extension_drop_test_grantor; REVOKE USAGE ON SCHEMA %1$I FROM extension_drop_test_grantor', :'extension_drop_schema')
  , 'REVOKE from a role other than PUBLIC is allowed'
);

/*
 * PUBLIC's USAGE can survive a REVOKE by the owner because another role granted it too; DROP OWNED BY
 * that role then removes it.
 */
SELECT lives_ok(
  format($q$GRANT USAGE ON SCHEMA %1$I TO extension_drop_test_grantor WITH GRANT OPTION;
    SELECT pg_temp.xd_as('extension_drop_test_grantor', %2$L);
    REVOKE USAGE ON SCHEMA %1$I FROM PUBLIC$q$, :'extension_drop_schema'
    , format('GRANT USAGE ON SCHEMA %I TO PUBLIC', :'extension_drop_schema'))
  , 'PUBLIC keeps USAGE through the grantor''s own grant'
);
SELECT throws_ok(
  'DROP OWNED BY extension_drop_test_grantor'
  , '55000'
  , :'removal_msg'
  , 'DROP OWNED BY the grantor of PUBLIC''s only USAGE is rejected'
);
SELECT lives_ok(
  format($q$GRANT USAGE ON SCHEMA %I TO PUBLIC; DROP OWNED BY extension_drop_test_grantor$q$, :'extension_drop_schema')
  , 'DROP OWNED BY the grantor is allowed once PUBLIC has USAGE from the owner'
);

/*
 * A superuser can bypass the guard; afterwards every REVOKE and DROP OWNED fails before running, naming the
 * state and the fix.
 */
SELECT lives_ok(
  format('SET LOCAL session_replication_role = replica; REVOKE USAGE ON SCHEMA %I FROM PUBLIC; RESET session_replication_role', :'extension_drop_schema')
  , 'Remove PUBLIC''s USAGE with event triggers bypassed'
);
SELECT throws_ok(
  format('REVOKE USAGE ON SCHEMA %I FROM extension_drop_test_grantor', :'extension_drop_schema')
  , '55000'
  , :'lacks_msg'
  , 'An unrelated REVOKE reports the missing USAGE'
);
SELECT results_eq(
  format(:'capture_query', format('REVOKE USAGE ON SCHEMA %I FROM extension_drop_test_grantor', :'extension_drop_schema'))
  , format($$VALUES (%L, 'extension_drop requires PUBLIC to have USAGE on the schema it is installed in. DDL command: REVOKE')$$, :'lacks_hint')
  , 'HINT gives the GRANT; DETAIL explains the requirement and names the command'
);
SELECT throws_ok(
  'DROP OWNED BY extension_drop_test_grantor'
  , '55000'
  , :'lacks_msg'
  , 'DROP OWNED reports the missing USAGE'
);
SELECT lives_ok(
  format('GRANT USAGE ON SCHEMA %I TO PUBLIC', :'extension_drop_schema')
  , 'The GRANT in the HINT recovers'
);

/*
 * Install and update. This file's transaction is rolled back, so extension_drop can be dropped and
 * reinstalled elsewhere regardless of how the suite installed it. CASCADE: existing mode plants a
 * dependent guard object, whose drop notice is hidden to keep the output mode-independent.
 */
SET LOCAL client_min_messages = warning;
SELECT lives_ok(
  'DROP EXTENSION extension_drop CASCADE'
  , 'Drop extension_drop'
);

CREATE SCHEMA "xd no usage";
SELECT throws_ok(
  'CREATE EXTENSION extension_drop SCHEMA "xd no usage"'
  , '55000'
  , 'cannot install extension_drop in schema "xd no usage"'
  , 'Install into a schema without PUBLIC USAGE fails'
);
SELECT results_eq(
  format(:'capture_query', $q$CREATE EXTENSION extension_drop SCHEMA "xd no usage"$q$)
  , format($$VALUES (%L, 'extension_drop requires PUBLIC to have USAGE on the schema it is installed in.')$$, :'install_hint')
  , 'HINT gives the exact GRANT and names the restore setting; DETAIL explains the requirement'
);

-- The 0.1.1 install script predates the requirement; the update must enforce it, and cope with any schema name
CREATE SCHEMA "x$body$y";
/*
 * The frozen 0.1.1 script forces its own client_min_messages and calls a deprecated cat_tools function;
 * terse verbosity drops the server-version-dependent LOCATION line from that warning.
 */
\set VERBOSITY terse
CREATE EXTENSION extension_drop VERSION '0.1.1' SCHEMA "x$body$y";
\set VERBOSITY verbose
SELECT throws_ok(
  'ALTER EXTENSION extension_drop UPDATE'
  , '55000'
  , 'cannot update extension_drop in schema "x$body$y"'
  , 'Update of an install without PUBLIC USAGE fails'
);
SELECT results_eq(
  format(:'capture_query', $q$ALTER EXTENSION extension_drop UPDATE$q$)
  , format(
    $$VALUES (%L, 'extension_drop requires PUBLIC to have USAGE on the schema it is installed in.')$$
    , 'Run GRANT USAGE ON SCHEMA "x$body$y" TO PUBLIC (creating the schema first if needed), then retry. ' || :'restore_hint'
  )
  , 'HINT gives the exact GRANT and names the restore setting; DETAIL explains the requirement'
);
GRANT USAGE ON SCHEMA "x$body$y" TO PUBLIC;
SELECT lives_ok(
  'ALTER EXTENSION extension_drop UPDATE'
  , 'Update succeeds once PUBLIC has USAGE, in a schema named x$body$y'
);
-- pgTAP has no assertion for an extension's installed version
SELECT is(
  (SELECT extversion FROM pg_extension WHERE extname = 'extension_drop')
  , (SELECT default_version FROM pg_available_extensions WHERE name = 'extension_drop')
  , 'Updated to the current version'
);

/*
 * Restore mode. With extension_drop.missing_public_usage = 'grant', install and update queue the GRANT for
 * COMMIT instead of failing. This file's transaction never commits, so SET CONSTRAINTS ALL IMMEDIATE fires the
 * deferred trigger at the point COMMIT would.
 */
SELECT lives_ok(
  'DROP EXTENSION extension_drop'
  , 'Drop extension_drop'
);
CREATE SCHEMA "xd grant";
SET LOCAL extension_drop.missing_public_usage = 'grant';
-- Terse verbosity keeps the grant-mode WARNING's LOCATION line out of the expected output
\set VERBOSITY terse
SELECT lives_ok(
  'CREATE EXTENSION extension_drop SCHEMA "xd grant"'
  , 'grant: install into a schema without PUBLIC USAGE succeeds, with a warning'
);
\set VERBOSITY verbose
SELECT is(
  has_schema_privilege('public', 'xd grant', 'USAGE')
  , false
  , 'grant: PUBLIC has no USAGE before COMMIT'
);
SELECT isnt_empty(
  $$SELECT 1 FROM "xd grant".extension_drop__grant_queue$$
  , 'grant: the schema is queued'
);
SELECT lives_ok(
  'SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED'
  , 'grant: fire the deferred trigger, as COMMIT does'
);
SELECT is(
  has_schema_privilege('public', 'xd grant', 'USAGE')
  , true
  , 'grant: PUBLIC has USAGE after COMMIT'
);
SELECT is_empty(
  $$SELECT 1 FROM "xd grant".extension_drop__grant_queue$$
  , 'grant: the queue is empty again'
);
-- A pg_init_privs row is what makes pg_dump omit the grant, so the queued grant must not leave one
SELECT is_empty(
  $$SELECT 1 FROM pg_init_privs WHERE classoid = 'pg_namespace'::regclass AND objoid = '"xd grant"'::regnamespace$$
  , 'grant: no pg_init_privs row for the schema'
);
SELECT table_privs_are(
  'xd grant', 'extension_drop__grant_queue', 'public', '{}'
  , 'PUBLIC has no privileges on the queue table'
);
SELECT throws_ok(
  $$SELECT pg_temp.xd_as('extension_drop_test_grantor', 'INSERT INTO "xd grant".extension_drop__grant_queue VALUES (''xd grant'')')$$
  , '42501'
  , 'permission denied for table extension_drop__grant_queue'
  , 'A role without privileges on the queue cannot queue a grant'
);
-- The setting is still 'grant', so this also shows the guard ignores it
SELECT throws_ok(
  'REVOKE USAGE ON SCHEMA "xd grant" FROM PUBLIC'
  , '55000'
  , 'cannot remove USAGE on schema "xd grant" from PUBLIC'
  , 'An unqueued REVOKE is still refused'
);

-- The guard treats a queued grant as USAGE already present
SELECT lives_ok(
  'DROP EXTENSION extension_drop'
  , 'Drop extension_drop again'
);
CREATE SCHEMA "xd grant 2";
\set VERBOSITY terse
SELECT lives_ok(
  'CREATE EXTENSION extension_drop SCHEMA "xd grant 2"'
  , 'grant: install into a second schema'
);
\set VERBOSITY verbose
SELECT lives_ok(
  'REVOKE USAGE ON SCHEMA "xd grant 2" FROM PUBLIC'
  , 'REVOKE in the transaction of a queued grant is not refused'
);
SELECT lives_ok(
  'GRANT USAGE ON SCHEMA "xd grant 2" TO PUBLIC; REVOKE USAGE ON SCHEMA "xd grant 2" FROM PUBLIC'
  , 'GRANT then REVOKE in the transaction of a queued grant is not refused'
);
SELECT lives_ok(
  'SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED'
  , 'Fire the deferred trigger'
);
SELECT is(
  has_schema_privilege('public', 'xd grant 2', 'USAGE')
  , true
  , 'PUBLIC has USAGE after the queued grant ran'
);

-- Any other value is rejected; 'error' is the default behavior
SELECT lives_ok(
  'DROP EXTENSION extension_drop'
  , 'Drop extension_drop after the queued-grant guard tests'
);
SET LOCAL extension_drop.missing_public_usage = 'error';
SELECT throws_ok(
  'CREATE EXTENSION extension_drop SCHEMA "xd no usage"'
  , '55000'
  , 'cannot install extension_drop in schema "xd no usage"'
  , 'error: install into a schema without PUBLIC USAGE fails'
);
SET LOCAL extension_drop.missing_public_usage = 'skip';
SELECT throws_ok(
  'CREATE EXTENSION extension_drop SCHEMA "xd no usage"'
  , '22023'
  , 'invalid value for parameter "extension_drop.missing_public_usage": "skip"'
  , 'An invalid value is rejected'
);

-- Update, from a 0.1.1 install in a schema without PUBLIC USAGE
CREATE SCHEMA "xd grant upd";
\set VERBOSITY terse
CREATE EXTENSION extension_drop VERSION '0.1.1' SCHEMA "xd grant upd";
\set VERBOSITY verbose
SELECT throws_ok(
  'ALTER EXTENSION extension_drop UPDATE'
  , '22023'
  , 'invalid value for parameter "extension_drop.missing_public_usage": "skip"'
  , 'update: an invalid value is rejected'
);
SET LOCAL extension_drop.missing_public_usage = 'grant';
\set VERBOSITY terse
SELECT lives_ok(
  'ALTER EXTENSION extension_drop UPDATE'
  , 'grant: update of an install without PUBLIC USAGE succeeds, with a warning'
);
\set VERBOSITY verbose
SELECT is(
  has_schema_privilege('public', 'xd grant upd', 'USAGE')
  , false
  , 'grant: PUBLIC has no USAGE before COMMIT after an update'
);
SELECT isnt_empty(
  $$SELECT 1 FROM "xd grant upd".extension_drop__grant_queue$$
  , 'grant: the schema is queued by the update'
);
SELECT lives_ok(
  'SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED'
  , 'grant: fire the deferred trigger after an update'
);
SELECT is(
  has_schema_privilege('public', 'xd grant upd', 'USAGE')
  , true
  , 'grant: PUBLIC has USAGE after COMMIT after an update'
);
SELECT is_empty(
  $$SELECT 1 FROM pg_init_privs WHERE classoid = 'pg_namespace'::regclass AND objoid = '"xd grant upd"'::regnamespace$$
  , 'grant: no pg_init_privs row after an update'
);

/*
 * Installing into public after REVOKE must leave initdb's pg_init_privs row alone, which a GRANT in the
 * script would not.
 */
CREATE TEMP TABLE xd_public_init_privs AS
  SELECT * FROM pg_init_privs WHERE classoid = 'pg_namespace'::regclass AND objoid = 'public'::regnamespace;
SELECT lives_ok(
  'DROP EXTENSION extension_drop'
  , 'Drop extension_drop after the public install'
);
SELECT lives_ok(
  'REVOKE USAGE ON SCHEMA public FROM PUBLIC'
  , 'Revoke PUBLIC''s USAGE on public'
);
\set VERBOSITY terse
SELECT lives_ok(
  'CREATE EXTENSION extension_drop SCHEMA public'
  , 'grant: install into public'
);
\set VERBOSITY verbose
SELECT lives_ok(
  'SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED'
  , 'grant: fire the deferred trigger for public'
);
SELECT is(
  has_schema_privilege('public', 'public', 'USAGE')
  , true
  , 'grant: PUBLIC has USAGE on public again'
);
SELECT results_eq(
  $$SELECT * FROM pg_init_privs WHERE classoid = 'pg_namespace'::regclass AND objoid = 'public'::regnamespace$$
  , 'SELECT * FROM xd_public_init_privs'
  , 'initdb''s pg_init_privs row for public is unchanged'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
