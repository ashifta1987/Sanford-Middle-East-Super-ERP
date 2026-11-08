-- Sanford ERP - run on SAP B1 HANA (HANA Studio / DBeaver / SQL console), ONCE PER COMPANY DATABASE.
-- Replace SBO_SANFORD with that company's schema in every query, and save each result as CSV
-- with a header, in a folder named after the company code (e.g. AE01_SBO_SANFORD).
-- Queries 1-8 read structure only. Query 9 exports the data.

-- 1. Columns WITH order, decimal scale and default values
--    (the order is what the loader uses; defaults are re-applied in the app layer)
SELECT TABLE_NAME, POSITION, COLUMN_NAME, DATA_TYPE_NAME, LENGTH, SCALE,
       IS_NULLABLE, DEFAULT_VALUE
FROM SYS.TABLE_COLUMNS
WHERE SCHEMA_NAME = 'SBO_SANFORD'
ORDER BY TABLE_NAME, POSITION;

-- 2. Primary keys and unique keys  ->  save as constraints.csv, feed to apply_keys.py
SELECT TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME, POSITION, IS_PRIMARY_KEY, IS_UNIQUE_KEY
FROM SYS.CONSTRAINTS
WHERE SCHEMA_NAME = 'SBO_SANFORD'
ORDER BY TABLE_NAME, CONSTRAINT_NAME, POSITION;

-- 3. Indexes (for query performance in Supabase)
SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME, POSITION, CONSTRAINT
FROM SYS.INDEX_COLUMNS
WHERE SCHEMA_NAME = 'SBO_SANFORD'
ORDER BY TABLE_NAME, INDEX_NAME, POSITION;

-- 4. Row counts and size  ->  save as row_counts.csv, the loader checks every table against it
SELECT TABLE_NAME, RECORD_COUNT, TABLE_SIZE
FROM M_TABLES
WHERE SCHEMA_NAME = 'SBO_SANFORD'
ORDER BY RECORD_COUNT DESC;

-- 5. User-defined field definitions (labels, defaults, linked tables)
SELECT "TableID", "FieldID", "AliasID", "Descr", "TypeID", "EditType", "SizeID",
       "EditSize", "Dflt", "NotNull", "RTable", "RelUDO"
FROM "SBO_SANFORD"."CUFD";

-- 6. Dropdown values for user-defined fields
SELECT "TableID", "FieldID", "IndexID", "FldValue", "Descr"
FROM "SBO_SANFORD"."UFD1";

-- 7. NEW - who this database belongs to (fills sap._company)
SELECT "CompnyName", "Country", "MainCurncy", "SysCurrncy", "TaxIdNum", "FreeZoneNo", "CompnyAddr"
FROM "SBO_SANFORD"."OADM";

-- 8. NEW - definitions of the HANA views the stock and batch reports use
--    (OINM, OIBT, IBT1, OSRD, OSRI, SRI1, VTSP are views on HANA, not tables)
SELECT VIEW_NAME, DEFINITION
FROM SYS.VIEWS
WHERE SCHEMA_NAME = 'SBO_SANFORD'
  AND VIEW_NAME IN ('OINM', 'OIBT', 'IBT1', 'OSRD', 'OSRI', 'SRI1', 'VTSP');

-- 9. NEW - the data itself: every table, every year, as CSV (needs the EXPORT privilege)
--    Writes one folder per table with create.sql (column order) and the data file(s).
EXPORT "SBO_SANFORD"."*" AS CSV INTO '/hana/export/AE01_SBO_SANFORD' WITH REPLACE THREADS 4;
