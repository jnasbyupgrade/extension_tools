/*
 * NOTE: All pg_temp objects must be dropped at the end of the script!
 * Otherwise the eventual DROP CASCADE of pg_temp when the session ends will
 * also drop the extension! Instead of risking problems, create our own
 * "temporary" schema instead.
 */
CREATE SCHEMA __extension_drop;

CREATE FUNCTION __extension_drop.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$;

CREATE FUNCTION __extension_drop.safe_dump(
  relation regclass
  , filter text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  PERFORM pg_catalog.pg_extension_config_dump(relation, filter);
EXCEPTION WHEN feature_not_supported THEN
  NULL;
END
$body$;

CREATE FUNCTION __extension_drop.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  c_clean_args text := cat_tools.routine__parse_arg_types_text(args);

  create_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION %s(
%s
) RETURNS %s SET search_path FROM CURRENT AS
%L
$template$
  ;

  revoke_template CONSTANT text := $template$
REVOKE ALL ON FUNCTION %s(
%s
) FROM public;
$template$
  ;

  grant_template CONSTANT text := $template$
GRANT EXECUTE ON FUNCTION %s(
%s
) TO %s;
$template$
  ;

  comment_template CONSTANT text := $template$
COMMENT ON FUNCTION %s(
%s
) IS %L;
$template$
  ;

BEGIN
  PERFORM __extension_drop.exec( format(
      create_template
      , function_name
      , args
      , options -- TODO: Force search_path if options ~* 'definer'
      , body
    ) )
  ;

  IF grants IS NOT NULL THEN
    PERFORM __extension_drop.exec( format(
        revoke_template
        , function_name
        , c_clean_args
      ) )
    ;
    IF grants <> '' THEN
      PERFORM __extension_drop.exec( format(
          grant_template
          , function_name
          , c_clean_args
          , grants
        ) )
      ;
    END IF;
  END IF;

  IF comment IS NOT NULL THEN
    PERFORM __extension_drop.exec( format(
        comment_template
        , function_name
        , c_clean_args
        , comment
      ) )
    ;
  END IF;
END
$body$;

CREATE TABLE extension_drop__commands(
  extension_name name PRIMARY KEY
  , sql text NOT NULL
);
SELECT __extension_drop.safe_dump('extension_drop__commands', '');

SELECT __extension_drop.create_function(
  'extension_drop__sanity_check'
  , 'ignore name DEFAULT NULL'
  , 'name[] LANGUAGE sql STABLE'
  , $body$
SELECT array(
  SELECT extension_name
    FROM extension_drop__commands c
    WHERE NOT EXISTS(SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = c.extension_name)
      AND extension_name IS DISTINCT FROM ignore
  )
$body$
  , $$Returns an array of extensions that have drop commands but do not exist. This array should always be empty!$$
);

SELECT __extension_drop.create_function(
  'extension_drop__sanity_assert'
  , 'ignore name DEFAULT NULL'
  , 'void LANGUAGE plpgsql STABLE'
  , $body$
DECLARE
  bad name[] := extension_drop__sanity_check(ignore);
BEGIN
  IF bad != '{}'::name[] THEN
    RAISE 'unexpected drop commands'
      USING ERRCODE = 'XD001'
        , HINT = $$This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.
  Use SELECT extension_drop__repair() to fix this.$$
        , DETAIL = format(
          '%s not exist: %s'
          , CASE WHEN array_length(bad, 1) = 1 THEN 'This extension does' ELSE 'These extensions do' END
          , array_to_string(bad, ', ')
        )
    ;
  END IF;
END
$body$
  , $$Throws an error if the "extension_drop__commands" table is not in a sane state.$$
);

/*
 * REPAIR
 */
SELECT __extension_drop.create_function(
  'extension_drop__repair'
  , ''
  , 'void LANGUAGE sql'
  , $body$
DELETE FROM extension_drop__commands WHERE extension_name = ANY( extension_drop__sanity_check() )
$body$
  , 'Repairs the "extension_drop__commands" table. THIS FUNCTION SHOULD NEVER BE NEEDED.'
  , '' -- Just revoke all access
);

/*
 * GET
 */
SELECT __extension_drop.create_function(
  'extension_drop__get'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
$$
  , 'extension_drop__commands STABLE LANGUAGE plpgsql'
  , $body$
DECLARE
  ret extension_drop__commands;
BEGIN
  PERFORM extension_drop__sanity_assert();
  SELECT INTO STRICT ret
      *
    FROM extension_drop__commands d
    WHERE d.extension_name = extension_drop__get.extension_name
  ;

  RETURN ret;

EXCEPTION WHEN no_data_found THEN
  RAISE 'no drop commands for extension "%"', extension_name
    USING errcode = 'no_data_found'
  ;
END
$body$
  , $$Get info about a set of commands to be run when an extension is dropped.$$
);

/*
 * ADD
 */
SELECT __extension_drop.create_function(
  'extension_drop__add'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
  , sql extension_drop__commands.sql%TYPE
$$
  , 'void LANGUAGE plpgsql'
  , $body$
BEGIN
  INSERT INTO extension_drop__commands VALUES(extension_name, sql);
  PERFORM extension_drop__sanity_assert();
END
$body$
  , $$Adds a set of commands to be run when an extension is dropped.$$
  , '' -- Just revoke all access
);

/*
 * REMOVE
 */
SELECT __extension_drop.create_function(
  'extension_drop__remove'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
$$
  , 'void LANGUAGE sql'
  , $body$
DELETE FROM extension_drop__commands d
  -- extension_drop__get() runs sanity checks for us
  WHERE d.extension_name = (extension_drop__get(extension_name)).extension_name
$body$
  , $$Remove a set of commands to be run when an extension is dropped.$$
  , '' -- Just revoke all access
);

/*
 * UPDATE
 */
SELECT __extension_drop.create_function(
  'extension_drop__update'
  , $$
  extension_name extension_drop__commands.extension_name%TYPE
  , sql extension_drop__commands.sql%TYPE
$$
  , 'void LANGUAGE sql'
  , $body$
UPDATE extension_drop__commands d
  SET sql = extension_drop__update.sql
  -- extension_drop__get() runs sanity checks for us
  WHERE d.extension_name = (extension_drop__get(extension_name)).extension_name
$body$
  , $$Update the set of commands to be run when an extension is dropped.$$
  , '' -- Just revoke all access
);

/*
 * TRIGGER FUNCTION
 */
SELECT __extension_drop.create_function(
  'extension_drop__event_trigger'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
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
$body$
  , 'Event trigger function that does the actual work for extension_drop.'
);

CREATE EVENT TRIGGER extension_drop
  ON sql_drop
  -- DROP SCHEMA CASCADE and DROP OWNED BY also drop extensions.
  WHEN tag IN( 'DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED' ) -- NOTE! This MUST be IN
  EXECUTE PROCEDURE extension_drop__event_trigger()
;

/*
 * Drop "temporary" objects
 */
DROP FUNCTION __extension_drop.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text
);
DROP FUNCTION __extension_drop.safe_dump(
  relation regclass
  , text
);
DROP FUNCTION __extension_drop.exec(
  sql text
);
DROP SCHEMA __extension_drop;

-- vim: sw=2 ts=2 expandtab
