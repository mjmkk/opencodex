CREATE TABLE IF NOT EXISTS threads (
 account_namespace text NOT NULL, thread_id text NOT NULL, kind text, host_id text,
 metadata jsonb NOT NULL DEFAULT '{}', observed_version text, synced_version text,
 last_seen_at timestamptz, last_checked_at timestamptz, last_synced_at timestamptz,
 content_coverage text NOT NULL DEFAULT 'unknown' CHECK(content_coverage IN ('unknown','partial','complete')),
 attachment_coverage text NOT NULL DEFAULT 'unknown' CHECK(attachment_coverage IN ('unknown','partial','none','complete')),
 upstream_state text NOT NULL DEFAULT 'unknown', coverage_detail jsonb NOT NULL DEFAULT '{}',
 latest_raw jsonb, latest_attempt_raw jsonb,
 PRIMARY KEY(account_namespace,thread_id));
-- Append-only row facts survive rebuilding all derived current/revision tables.
CREATE TABLE IF NOT EXISTS raw_facts (
 seq bigserial PRIMARY KEY, account_namespace text NOT NULL, thread_id text NOT NULL,
 category text NOT NULL, native_id text NOT NULL, payload_hash text NOT NULL,
 observed_at timestamptz NOT NULL DEFAULT now(), raw_payload jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS thread_metadata_revisions (
 fact_seq bigint PRIMARY KEY REFERENCES raw_facts(seq), account_namespace text NOT NULL, thread_id text NOT NULL,
 payload_hash text NOT NULL, observed_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS messages (
 account_namespace text NOT NULL, thread_id text NOT NULL, native_id text NOT NULL, role text NOT NULL,
 text_content text NOT NULL, payload_hash text NOT NULL, fact_seq bigint NOT NULL REFERENCES raw_facts(seq),
 last_seen_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(account_namespace,thread_id,native_id));
CREATE TABLE IF NOT EXISTS message_revisions (
 fact_seq bigint PRIMARY KEY REFERENCES raw_facts(seq), account_namespace text NOT NULL, thread_id text NOT NULL,
 native_id text NOT NULL, role text NOT NULL, text_content text NOT NULL, payload_hash text NOT NULL,
 observed_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS thread_items (
 account_namespace text NOT NULL, thread_id text NOT NULL, native_id text NOT NULL, type text NOT NULL,
 payload_hash text NOT NULL, fact_seq bigint NOT NULL REFERENCES raw_facts(seq),
 last_seen_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(account_namespace,thread_id,native_id));
CREATE TABLE IF NOT EXISTS thread_item_revisions (
 fact_seq bigint PRIMARY KEY REFERENCES raw_facts(seq), account_namespace text NOT NULL, thread_id text NOT NULL,
 native_id text NOT NULL, type text NOT NULL, payload_hash text NOT NULL,
 observed_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS attachments (
 account_namespace text NOT NULL, thread_id text NOT NULL, native_id text NOT NULL,
 filename text, mime text, upstream_metadata jsonb NOT NULL, state text NOT NULL DEFAULT 'pending',
 blob jsonb, last_error text, observed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(account_namespace,thread_id,native_id));
CREATE TABLE IF NOT EXISTS attachment_blobs (
 account_namespace text NOT NULL, thread_id text NOT NULL, native_id text NOT NULL,
 sha256 text NOT NULL, blob jsonb NOT NULL, observed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(account_namespace,thread_id,native_id,sha256));
CREATE TABLE IF NOT EXISTS queue (
 id bigserial PRIMARY KEY, account_namespace text NOT NULL, thread_id text NOT NULL,
 kind text NOT NULL, item_id text NOT NULL DEFAULT '', state text NOT NULL DEFAULT 'pending',
 requested boolean NOT NULL DEFAULT false, attempts int NOT NULL DEFAULT 0,
 available_at timestamptz NOT NULL DEFAULT now(), started_at timestamptz, last_error text,
 UNIQUE(account_namespace,thread_id,kind,item_id));
CREATE INDEX IF NOT EXISTS queue_ready ON queue(account_namespace,state,available_at);
CREATE TABLE IF NOT EXISTS sync_state (
 account_namespace text PRIMARY KEY, scan_running boolean NOT NULL DEFAULT false,
 scan_requested boolean NOT NULL DEFAULT false, last_scan_at timestamptz,
 concurrency int NOT NULL DEFAULT 4, stable_count int NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS sync_errors (
 id bigserial PRIMARY KEY, account_namespace text NOT NULL, thread_id text,
 kind text NOT NULL, detail text NOT NULL, observed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS discovery_scans (
 id bigserial PRIMARY KEY, account_namespace text NOT NULL, observed_at timestamptz NOT NULL DEFAULT now(),
 raw_blob jsonb NOT NULL, found_count int, status text NOT NULL DEFAULT 'saved', detail jsonb NOT NULL DEFAULT '{}');
CREATE TABLE IF NOT EXISTS registry_observations (
 account_namespace text NOT NULL, issue_id text NOT NULL, source_updated_at text NOT NULL,
 registry jsonb NOT NULL, observed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(account_namespace,issue_id));
CREATE INDEX IF NOT EXISTS raw_facts_identity ON raw_facts(account_namespace,thread_id,category,native_id,seq DESC);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS first_fact_seq bigint;
UPDATE messages SET first_fact_seq=fact_seq WHERE first_fact_seq IS NULL;
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS refresh_used boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS snapshots (
 account_namespace text NOT NULL, thread_id text NOT NULL, slot text NOT NULL,
 raw_blob jsonb NOT NULL, PRIMARY KEY(account_namespace,thread_id,slot));
CREATE TABLE IF NOT EXISTS message_order (
 account_namespace text NOT NULL, thread_id text NOT NULL, native_id text NOT NULL,
 sort_key text NOT NULL, PRIMARY KEY(account_namespace,thread_id,native_id));
-- PostgreSQL jsonb rejects valid upstream JSON escape sequences such as \u0000.
-- JSON preserves those exact values; indexes use dedicated relational columns.
-- Existing installations may still contain duplicated derived raw columns.
-- Initialization does not remove them: explicit audited migration owns that step.
DO $migration$
DECLARE target record; actual_type text;
BEGIN
 FOR target IN SELECT * FROM (VALUES
  ('threads','metadata',false), ('raw_facts','raw_payload',false),
  ('thread_metadata_revisions','raw_payload',false), ('messages','raw_payload',false),
  ('messages','text_content',true), ('message_revisions','raw_payload',false),
  ('message_revisions','text_content',true), ('thread_items','raw_payload',false),
  ('thread_item_revisions','raw_payload',false), ('attachments','upstream_metadata',false)
 ) AS fields(table_name,column_name,is_body)
 LOOP
  SELECT a.atttypid::regtype::text INTO actual_type FROM pg_attribute a
   WHERE a.attrelid=to_regclass(target.table_name) AND a.attname=target.column_name
     AND a.attnum>0 AND NOT a.attisdropped;
  IF actual_type IS NOT NULL AND actual_type <> 'json' THEN
   EXECUTE format('ALTER TABLE %I ALTER COLUMN %I TYPE json USING %s',
    target.table_name,target.column_name,
    CASE WHEN target.is_body THEN format('to_json(%I)',target.column_name)
         ELSE format('%I::json',target.column_name) END);
  END IF;
 END LOOP;
END $migration$;

-- v2 is additive: historical textual JSON remains readable until audited migration.
ALTER TABLE raw_facts ALTER COLUMN raw_payload DROP NOT NULL;
ALTER TABLE raw_facts ADD COLUMN IF NOT EXISTS format_version smallint NOT NULL DEFAULT 1;
ALTER TABLE raw_facts ADD COLUMN IF NOT EXISTS payload_codec text;
ALTER TABLE raw_facts ADD COLUMN IF NOT EXISTS original_length bigint;
ALTER TABLE raw_facts ADD COLUMN IF NOT EXISTS original_bytes_sha256 bytea;
ALTER TABLE raw_facts ADD COLUMN IF NOT EXISTS encoded_length bigint;
ALTER TABLE raw_facts ADD COLUMN IF NOT EXISTS encoded_payload bytea;
ALTER TABLE raw_facts ALTER COLUMN encoded_payload SET STORAGE EXTERNAL;
ALTER TABLE attachments ALTER COLUMN upstream_metadata DROP NOT NULL;
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS metadata_fact_seq bigint REFERENCES raw_facts(seq);
DO $v2$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='raw_facts'::regclass AND conname='raw_facts_v2_shape') THEN
  ALTER TABLE raw_facts ADD CONSTRAINT raw_facts_v2_shape CHECK (
   (format_version=1 AND raw_payload IS NOT NULL AND encoded_payload IS NULL) OR
   (format_version=2 AND raw_payload IS NULL AND payload_codec IN ('zstd','none')
    AND payload_codec IS NOT NULL AND original_length>=0 AND original_length IS NOT NULL
    AND octet_length(original_bytes_sha256)=32 AND original_bytes_sha256 IS NOT NULL
    AND encoded_length>=18 AND encoded_length IS NOT NULL AND encoded_payload IS NOT NULL)) NOT VALID;
 END IF;
END $v2$;
