\set ECHO none
BEGIN;
\i test/pgxntool/psql.sql

CREATE EXTENSION IF NOT EXISTS cat_tools;

/*
 * extension_drop is already installed globally (test/install/load.sql,
 * committed) by the time this file runs. This test's whole point is running
 * the raw install SCRIPT directly (not via CREATE EXTENSION) to verify it
 * builds cleanly, so it needs the committed copy out of the way first --
 * otherwise the script's own CREATE TABLE extension_drop__commands collides
 * with the one that's already there. Safe to drop here: like every other
 * test/sql/ file, this one's changes never survive past its own session.
 */
DROP EXTENSION IF EXISTS extension_drop CASCADE;

\echo
\echo INSTALL
\t
\i sql/extension_drop.sql

\echo # TRANSACTION INTENTIONALLY LEFT OPEN
