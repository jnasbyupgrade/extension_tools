CREATE OR REPLACE FUNCTION extension_drop__event_trigger(
) RETURNS event_trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS
$body$
DECLARE
  /*
   * record, not extension_drop__commands: a typed variable is resolved when the function compiles, before
   * the early return, and a role without access to the extension's schema then fails every unrelated DROP.
   */
  t record;
  dropping text;
  names text[];
  cmds text[];
  i int;
  msg text;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;

  -- Most drops involve no extension; don't touch our table (or assert) for them.
  SELECT pg_catalog.string_agg(pg_catalog.quote_ident(object_name), ', ' ORDER BY object_name)
    INTO dropping
    FROM pg_catalog.pg_event_trigger_dropped_objects()
    WHERE object_type = 'extension';
  IF dropping IS NULL THEN
    RETURN;
  END IF;

  /*
   * One statement touches the table, so a privilege error here is ours; registered SQL runs after the
   * handler so its own errors pass through untouched.
   */
  BEGIN
    WITH del AS (
      DELETE FROM extension_drop__commands c
        USING pg_catalog.pg_event_trigger_dropped_objects() d
        WHERE c.extension_name = d.object_name AND d.object_type = 'extension'
        RETURNING c.extension_name, c.sql
    )
    SELECT pg_catalog.array_agg(extension_name), pg_catalog.array_agg(sql) INTO names, cmds FROM del;
  EXCEPTION WHEN insufficient_privilege OR undefined_table THEN
    -- undefined_table: name lookup skips a schema the caller lacks USAGE on, so the table "doesn't exist".
    GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;

    -- Look up the table by OID path, not by name, for the same reason.
    SELECT n.nspname, pg_catalog.format('%I.%I', n.nspname, c.relname) AS qname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
      INTO t
      FROM pg_catalog.pg_extension e
        JOIN pg_catalog.pg_class c
          ON c.relnamespace = e.extnamespace AND c.relname = 'extension_drop__commands'
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE e.extname = 'extension_drop';
    IF NOT FOUND THEN
      RAISE;
    END IF;

    RAISE EXCEPTION 'permission denied to drop extension(s) %', dropping
      USING ERRCODE = 'insufficient_privilege'
        , DETAIL = pg_catalog.format(
            'extension_drop must read and delete its registration in %s: %s', t.qname, msg)
        , HINT = pg_catalog.format(
            'Run the drop as role %s or a superuser, or grant USAGE on schema %s and SELECT, DELETE on %s to the current role.'
            , pg_catalog.quote_ident(t.owner), pg_catalog.quote_ident(t.nspname), t.qname);
  END;

  FOR i IN 1 .. COALESCE(pg_catalog.array_length(cmds, 1), 0) LOOP
    RAISE DEBUG E'extension "%" is being dropped; executing SQL:\n%', names[i], cmds[i];
    EXECUTE cmds[i];
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
