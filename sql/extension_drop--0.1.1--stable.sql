/*
 * The install script's create_function doesn't exist here, so build the helper directly; see
 * extension_drop.sql for why it is SECURITY DEFINER with a pg_catalog-only search_path.
 */
DO $do$
DECLARE
  sp text;
BEGIN
  SELECT pg_catalog.quote_ident(n.nspname) INTO sp
    FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'extension_drop';
  EXECUTE pg_catalog.format($f$
CREATE OR REPLACE FUNCTION extension_drop__registered(
  extension_names name[]
) RETURNS name[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$body$
DECLARE
  ret name[] := array(
    SELECT c.extension_name FROM %1$s.extension_drop__commands c
      WHERE c.extension_name = ANY(extension_names) ORDER BY 1
  );
  bad name[];
BEGIN
  /*
   * With nothing registered the trigger returns without reaching its own sanity assert, so any stale row is
   * caught here. Inlined rather than calling extension_drop__sanity_assert(): that resolves names through
   * its owner's search_path, which must not happen with definer rights.
   */
  IF pg_catalog.array_length(ret, 1) IS NULL THEN
    bad := array(
      SELECT c.extension_name FROM %1$s.extension_drop__commands c
        WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = c.extension_name)
    );
    IF pg_catalog.array_length(bad, 1) IS NOT NULL THEN
      RAISE 'unexpected drop commands'
        USING ERRCODE = 'XD001'
          , HINT = $$This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.
    Use SELECT extension_drop__repair() to fix this.$$
          , DETAIL = pg_catalog.format(
            '%%s not exist: %%s'
            , CASE WHEN pg_catalog.array_length(bad, 1) = 1 THEN 'This extension does' ELSE 'These extensions do' END
            , pg_catalog.array_to_string(bad, ', ')
          )
      ;
    END IF;
  END IF;
  RETURN ret;
END
$body$
$f$, sp);
END
$do$;
REVOKE ALL ON FUNCTION extension_drop__registered(name[]) FROM public;
GRANT EXECUTE ON FUNCTION extension_drop__registered(name[]) TO public;
COMMENT ON FUNCTION extension_drop__registered(name[]) IS
  $$Returns the given extensions that have drop commands, after asserting the table is sane if there are none.$$;

CREATE OR REPLACE FUNCTION extension_drop__event_trigger(
) RETURNS event_trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS
$body$
DECLARE
  t record;
  dropping text;
  dropped name[];
  registered name[];
  names text[];
  cmds text[];
  i int;
  msg text;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;

  -- Most drops involve no extension; don't touch our table (or assert) for them.
  SELECT pg_catalog.string_agg(
          pg_catalog.format('"%s"', pg_catalog.replace(object_name, '"', '""')), ', ' ORDER BY object_name)
      , pg_catalog.array_agg(object_name::name ORDER BY object_name)
    INTO dropping, dropped
    FROM pg_catalog.pg_event_trigger_dropped_objects()
    WHERE object_type = 'extension';
  IF dropping IS NULL THEN
    RETURN;
  END IF;

  /*
   * Callers without table access can still drop unregistered extensions. Without USAGE on our schema the
   * helper isn't found; fall through to the DELETE below for its clearer error.
   */
  BEGIN
    registered := extension_drop__registered(dropped);
  EXCEPTION WHEN undefined_function OR insufficient_privilege THEN
    registered := NULL;
  END;
  IF registered = '{}'::name[] THEN
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
    SELECT n.nspname, c.relname, pg_catalog.format('%I.%I', n.nspname, c.relname) AS qname, pg_catalog.pg_get_userbyid(c.relowner) AS owner
      INTO t
      FROM pg_catalog.pg_extension e
        JOIN pg_catalog.pg_class c
          ON c.relnamespace = e.extnamespace AND c.relname = 'extension_drop__commands'
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE e.extname = 'extension_drop';
    IF NOT FOUND THEN
      RAISE;
    END IF;

    -- Names are always double-quoted (embedded quotes doubled), the same way in every part of the message.
    RAISE EXCEPTION 'permission denied for table %.% (owned by role %), which extension_drop needs to drop extension(s) %'
        , pg_catalog.format('"%s"', pg_catalog.replace(t.nspname, '"', '""'))
        , pg_catalog.format('"%s"', pg_catalog.replace(t.relname, '"', '""'))
        , pg_catalog.format('"%s"', pg_catalog.replace(t.owner, '"', '""'))
        , dropping
      USING ERRCODE = 'insufficient_privilege'
        , DETAIL = msg
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
