-- Remove duplicate "Default" workspaces left by the ensureUserHasWorkspace()
-- race (several concurrent first requests each created one; fixed in
-- workspace-service.ts). MANUAL, not a migration: run it yourself, read the
-- dry run first.
--
-- Usage (dry run, the default: reports and deletes nothing):
--   psql "$DATABASE_URL" -f scripts/dedupe-default-workspaces.sql
--   kubectl exec -i -n optio <postgres-pod> -- psql -U optio optio \
--     < scripts/dedupe-default-workspaces.sql
--
-- Delete (only after reading the dry run; take a backup first):
--   psql "$DATABASE_URL" -v apply=1 -f scripts/dedupe-default-workspaces.sql
--
-- Optional, off by default: also delete the chart migration's `slug = 'default'`
-- workspace ("Default workspace for existing data") when it is empty:
--   ... -v apply=1 -v delete_chart_default=1 ...
--
-- What it does, per user who is a member of more than one workspace they
-- created themselves:
--   * keeps one: the workspace users.default_workspace_id points at when it is
--     one of those (and they're still a member), else the one with the
--     earliest workspace_members.created_at;
--   * of the others, a candidate is only an auto-created one: name 'Default'
--     and slug `ws-<first 8 of user id>` or `ws-<first 8>-<6 hex>`. Workspaces
--     the user created and named themselves are never touched;
--   * a candidate is deleted only when it is EMPTY: the creator is its only
--     member, it is nobody's default workspace, and no row in ANY table with a
--     workspace_id column (repos, tasks, secrets, config_objects,
--     config_sources, usage_budgets, connections, work_definitions, prompts,
--     agents, usage_ledger, ... — discovered at run time, not a fixed list)
--     points at it. Many of those tables have no foreign key to workspaces,
--     so a delete would orphan their rows rather than fail; hence the check.
--
-- Every decision is logged as a NOTICE (KEEP / DELETE / WOULD DELETE / SKIP
-- with the reason). The whole run is one transaction. Idempotent: a second
-- run finds nothing left to delete. Best run with the API scaled to zero (or
-- in a quiet window) so nothing writes to a candidate between check and delete.

\set ON_ERROR_STOP on
\if :{?apply}
\else
  \set apply 0
\endif
\if :{?delete_chart_default}
\else
  \set delete_chart_default 0
\endif

SELECT set_config('optio_dedupe.apply', :'apply', false) AS apply,
       set_config('optio_dedupe.delete_chart_default', :'delete_chart_default', false)
         AS delete_chart_default;

BEGIN;

DO $dedupe$
DECLARE
  do_apply boolean := current_setting('optio_dedupe.apply') IN ('1', 'true', 'on', 'yes');
  do_chart boolean :=
    current_setting('optio_dedupe.delete_chart_default') IN ('1', 'true', 'on', 'yes');
  ref_tables text[];
  u record;
  w record;
  keep_id uuid;
  tbl text;
  n bigint;
  why text;
  deleted int := 0;
  would int := 0;
  skipped int := 0;
BEGIN
  -- Every base table that points at a workspace (by a workspace_id column, or
  -- any foreign key to workspaces), except the membership rows themselves.
  SELECT array_agg(DISTINCT format('%I.%I', s, t) || ':' || col)
    INTO ref_tables
    FROM (
      SELECT c.table_schema AS s, c.table_name AS t, c.column_name AS col
        FROM information_schema.columns c
        JOIN information_schema.tables it
          ON it.table_schema = c.table_schema AND it.table_name = c.table_name
       WHERE c.table_schema = current_schema()
         AND it.table_type = 'BASE TABLE'
         AND c.column_name = 'workspace_id'
      UNION
      SELECT n.nspname, r.relname, a.attname
        FROM pg_constraint k
        JOIN pg_class r ON r.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace
        JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey)
       WHERE k.contype = 'f' AND k.confrelid = 'workspaces'::regclass
    ) refs
   WHERE t NOT IN ('workspace_members', 'workspaces', 'users');

  RAISE NOTICE 'mode: %', CASE WHEN do_apply THEN 'APPLY (deleting)' ELSE 'DRY RUN (nothing is deleted)' END;
  RAISE NOTICE 'checking % referencing tables', coalesce(array_length(ref_tables, 1), 0);

  FOR u IN
    SELECT m.user_id, us.email, us.default_workspace_id
      FROM workspace_members m
      JOIN workspaces ws ON ws.id = m.workspace_id AND ws.created_by = m.user_id
      JOIN users us ON us.id = m.user_id
     GROUP BY m.user_id, us.email, us.default_workspace_id
    HAVING count(*) > 1
     ORDER BY us.email
  LOOP
    -- The keeper: their default when it is one of their own, else the oldest.
    SELECT m.workspace_id INTO keep_id
      FROM workspace_members m
      JOIN workspaces ws ON ws.id = m.workspace_id AND ws.created_by = m.user_id
     WHERE m.user_id = u.user_id
     ORDER BY (m.workspace_id IS NOT DISTINCT FROM u.default_workspace_id) DESC,
              m.created_at ASC, m.workspace_id ASC
     LIMIT 1;
    RAISE NOTICE 'user % (%): KEEP workspace %', u.user_id, u.email, keep_id;

    FOR w IN
      SELECT ws.id, ws.name, ws.slug, ws.created_at
        FROM workspace_members m
        JOIN workspaces ws ON ws.id = m.workspace_id AND ws.created_by = m.user_id
       WHERE m.user_id = u.user_id AND ws.id <> keep_id
       ORDER BY ws.created_at
         FOR UPDATE OF ws
    LOOP
      why := NULL;
      IF w.slug = 'default' THEN
        why := 'chart migration workspace (handled separately)';
      ELSIF w.name <> 'Default'
         OR NOT (w.slug = 'ws-' || left(u.user_id::text, 8)
                 OR w.slug ~ ('^ws-' || left(u.user_id::text, 8) || '-[0-9a-f]{6}$')) THEN
        why := format('not an auto-created Default workspace (name %L, slug %L)', w.name, w.slug);
      END IF;
      IF why IS NULL THEN
        SELECT count(*) INTO n FROM workspace_members WHERE workspace_id = w.id AND user_id <> u.user_id;
        IF n > 0 THEN why := format('%s other member(s)', n); END IF;
      END IF;
      IF why IS NULL THEN
        SELECT count(*) INTO n FROM users WHERE default_workspace_id = w.id;
        IF n > 0 THEN why := format('default workspace of %s user(s)', n); END IF;
      END IF;
      IF why IS NULL THEN
        FOREACH tbl IN ARRAY coalesce(ref_tables, '{}') LOOP
          EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1',
                         split_part(tbl, ':', 1), split_part(tbl, ':', 2))
            INTO n USING w.id;
          IF n > 0 THEN
            why := format('%s row(s) in %s', n, tbl);
            EXIT;
          END IF;
        END LOOP;
      END IF;

      IF why IS NOT NULL THEN
        skipped := skipped + 1;
        RAISE NOTICE '  SKIP % (slug %, created %): %', w.id, w.slug, w.created_at, why;
      ELSIF do_apply THEN
        DELETE FROM workspaces WHERE id = w.id;
        deleted := deleted + 1;
        RAISE NOTICE '  DELETE % (slug %, created %)', w.id, w.slug, w.created_at;
      ELSE
        would := would + 1;
        RAISE NOTICE '  WOULD DELETE % (slug %, created %)', w.id, w.slug, w.created_at;
      END IF;
    END LOOP;
  END LOOP;

  -- The chart migration's workspace: reported always, deleted only on request
  -- and only when empty, nobody's default, and every member belongs elsewhere.
  FOR w IN SELECT id, name, slug, created_at FROM workspaces WHERE slug = 'default' FOR UPDATE LOOP
    why := NULL;
    SELECT count(*) INTO n FROM users WHERE default_workspace_id = w.id;
    IF n > 0 THEN why := format('default workspace of %s user(s)', n); END IF;
    IF why IS NULL THEN
      SELECT count(*) INTO n
        FROM workspace_members m
       WHERE m.workspace_id = w.id
         AND NOT EXISTS (SELECT 1 FROM workspace_members o
                          WHERE o.user_id = m.user_id AND o.workspace_id <> w.id);
      IF n > 0 THEN why := format('only workspace of %s member(s)', n); END IF;
    END IF;
    IF why IS NULL THEN
      FOREACH tbl IN ARRAY coalesce(ref_tables, '{}') LOOP
        EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1',
                       split_part(tbl, ':', 1), split_part(tbl, ':', 2))
          INTO n USING w.id;
        IF n > 0 THEN why := format('%s row(s) in %s', n, tbl); EXIT; END IF;
      END LOOP;
    END IF;

    IF why IS NOT NULL THEN
      RAISE NOTICE 'chart workspace % (slug default): KEEP, in use: %', w.id, why;
    ELSIF NOT do_chart THEN
      RAISE NOTICE 'chart workspace % (slug default): empty; kept (pass -v delete_chart_default=1 to delete)', w.id;
    ELSIF do_apply THEN
      DELETE FROM workspaces WHERE id = w.id;
      deleted := deleted + 1;
      RAISE NOTICE 'chart workspace % (slug default): DELETE (empty)', w.id;
    ELSE
      would := would + 1;
      RAISE NOTICE 'chart workspace % (slug default): WOULD DELETE (empty)', w.id;
    END IF;
  END LOOP;

  RAISE NOTICE 'done: % deleted, % would be deleted, % skipped', deleted, would, skipped;
END
$dedupe$;

COMMIT;
