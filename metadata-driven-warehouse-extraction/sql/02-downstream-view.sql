-- =====================================================================
--  The read-only interface exposed to the downstream team.
--  See Section 15 of the white paper.
--
--  A VIEW rather than the table itself, so that the control schema can
--  be restructured later without breaking the consumer, and so that
--  no write path into the control database is ever required.
-- =====================================================================

SET search_path TO extract_meta;

CREATE OR REPLACE VIEW vw_files_ready_for_load AS
SELECT c.source_schema,
       c.source_table,
       f.file_path,
       f.row_count,
       f.byte_size,
       f.published_datetime,
       f.file_id
FROM   md_file_log     f
JOIN   md_table_config c ON c.table_id = f.table_id
WHERE  f.published_datetime IS NOT NULL;

-- Grant read only. The downstream team never writes back: they keep
-- their own record of the highest published_datetime they have loaded.
--
--   CREATE ROLE downstream_reader;
--   GRANT USAGE  ON SCHEMA extract_meta TO downstream_reader;
--   GRANT SELECT ON vw_files_ready_for_load TO downstream_reader;

-- The query the downstream pipeline runs each time:
--
--   SELECT *
--   FROM   vw_files_ready_for_load
--   WHERE  published_datetime > :last_loaded_watermark
--   ORDER  BY published_datetime;
