CREATE OR REPLACE FUNCTION extension_drop__event_trigger(
) RETURNS event_trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS
$body$
DECLARE
  -- record, not extension_drop__commands: a typed variable is resolved when the function compiles, before
  -- the early return, and a role without access to the extension's schema then fails every unrelated DROP.
  r record;
BEGIN
  RAISE DEBUG 'extension_drop event trigger entry: tg_event %, tg_tag %', tg_event, tg_tag;

  -- Most drops involve no extension; don't touch our table (or assert) for them.
  IF NOT EXISTS(
    SELECT 1 FROM pg_catalog.pg_event_trigger_dropped_objects() WHERE object_type = 'extension'
  ) THEN
    RETURN;
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
