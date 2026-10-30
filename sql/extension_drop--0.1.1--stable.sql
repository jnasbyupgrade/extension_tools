CREATE OR REPLACE FUNCTION extension_drop__event_trigger(
) RETURNS event_trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS
$body$
DECLARE
  /*
   * record, not extension_drop__commands: a typed variable is resolved when the function compiles, before
   * the early return, and a role without access to the extension's schema then fails every unrelated DROP.
   */
  r record;
  t record;
  dropping text;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;

  -- Most drops involve no extension; don't touch our table (or assert) for them.
  IF NOT EXISTS(
    SELECT 1 FROM pg_catalog.pg_event_trigger_dropped_objects() WHERE object_type = 'extension'
  ) THEN
    RETURN;
  END IF;

  /*
   * Fail with an actionable error instead of the raw "permission denied" from the loop below. The table is
   * found by catalog OIDs, not by name: name lookup silently skips a schema the caller can't USE, which
   * would turn this into "does not exist". Not SECURITY DEFINER: that would run registered SQL as the owner.
   */
  SELECT c.oid AS oid, c.relnamespace, n.nspname, c.relname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
    INTO t
    FROM pg_catalog.pg_extension e
      JOIN pg_catalog.pg_class c
        ON c.relnamespace = e.extnamespace AND c.relname = 'extension_drop__commands'
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE e.extname = 'extension_drop';
  IF FOUND AND NOT (
    pg_catalog.has_schema_privilege(t.relnamespace, 'USAGE')
    AND pg_catalog.has_table_privilege(t.oid, 'SELECT')
    AND pg_catalog.has_table_privilege(t.oid, 'DELETE')
  ) THEN
    SELECT pg_catalog.string_agg(pg_catalog.quote_ident(object_name), ', ' ORDER BY object_name)
      INTO dropping
      FROM pg_catalog.pg_event_trigger_dropped_objects()
      WHERE object_type = 'extension';
    RAISE EXCEPTION 'permission denied to drop extension(s) %', dropping
      USING ERRCODE = 'insufficient_privilege'
        , DETAIL = pg_catalog.format(
            'extension_drop must read and delete its registration in %s.%s.'
            , pg_catalog.quote_ident(t.nspname), pg_catalog.quote_ident(t.relname))
        , HINT = pg_catalog.format(
            'Run the drop as role %s or a superuser, or grant USAGE on schema %s and SELECT, DELETE on %s.%s to the current role.'
            , pg_catalog.quote_ident(t.owner), pg_catalog.quote_ident(t.nspname)
            , pg_catalog.quote_ident(t.nspname), pg_catalog.quote_ident(t.relname));
  END IF;

  FOR r IN
    SELECT c.*
      FROM extension_drop__commands c
        JOIN pg_event_trigger_dropped_objects() d
          ON c.extension_name = d.object_name
            AND d.object_type = 'extension'
  LOOP
    RAISE DEBUG E'extension "%" is being dropped; executing SQL:\n%', r.extension_name, r.sql;
    EXECUTE r.sql;
    DELETE FROM extension_drop__commands WHERE extension_name = r.extension_name;
  END LOOP;

  /*
   * Need to do this after the fact since the extensions being dropped have
   * already been removed from the catalog by the time this function is called.
   */
  PERFORM extension_drop__sanity_assert();
END
$body$;

-- ALTER EVENT TRIGGER can't change WHEN
DROP EVENT TRIGGER extension_drop;
CREATE EVENT TRIGGER extension_drop
  ON sql_drop
  WHEN tag IN( 'DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__event_trigger()
;

-- vim: sw=2 ts=2 expandtab
