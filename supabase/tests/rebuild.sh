#!/bin/bash
# Full rebuild + regression in a fresh database, README run order, two companies (AE01, SA01) sharing codes.
#   bash mctest/rebuild.sh            (Postgres on localhost:5432, user postgres, PGPASSWORD set)
set -u
export PGPASSWORD=${PGPASSWORD:-pg}
B=$(cd "$(dirname "$0")/.." && pwd); O=$B/out; T=$B/mctest
DB=${DB:-mc_rebuild}
BASE="host=localhost port=5432 user=postgres"
DSN="$BASE dbname=$DB"
P() { psql "$DSN" -X -q -v ON_ERROR_STOP=1 "$@"; }
res() { printf '%-34s %-5s %s\n' "$1" "$2" "$3"; }
step() { local name=$1; shift; local t0=$(date +%s.%N); local out; out=$("$@" 2>&1); local rc=$?; local dt=$(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)");
         if [ $rc -eq 0 ]; then res "$name" PASS "${dt}s"; else res "$name" FAIL "${dt}s"; echo "$out" | grep -v NOTICE | tail -5; fi; return $rc; }

psql "$BASE dbname=postgres" -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB" || exit 1
echo "== fresh database $DB"
step "00_setup" P -f $O/00_setup.sql
step "01a_sap_standard" P -f $O/01a_sap_standard.sql
step "01b_addon_udt" P -f $O/01b_addon_udt.sql
res "  raw tables" "" "$(P -At -c "select count(*) from pg_tables where schemaname='sap' and tablename not like '\_%'")"
P -c "INSERT INTO sap._company VALUES ('AE01','SBO_SANFORD','Sanford Middle East DWC L.L.C','AE','AED','free_zone',true),('SA01','SBO_SANFORD_KSA','Sanford Japan Electronics Trading Company','SA','SAR','foreign',true)"
for co in AE01 SA01; do
  step "load_company $co" python3 $O/load_company.py --company $co --export $T/testexp/$co --columns $T/testexp/$co/columns.csv --counts $T/testexp/$co/row_counts.csv --dsn "$DSN password=$PGPASSWORD"
done
res "  load log" "" "$(P -At -F' ' -c "select string_agg(company_code||':'||status||'='||n, ' ') from (select company_code, status, count(*) n from sap._load_log group by 1,2 order by 1,2) x")"
res "  rows loaded = row_counts.csv" "" "$(P -At -c "select count(*) filter (where rows_expected = rows_loaded)||'/'||count(*) from sap._load_log")"
step "02_clean_blank_keys" P -f $O/02_clean_blank_keys.sql
ORPH=$(P -At -f $O/03_orphan_check.sql | grep -c '|')
[ "$ORPH" = 0 ] && res "03_orphan_check" PASS "0 orphan rows; sap._link $(P -At -c 'select count(*) from sap._link') links" || res "03_orphan_check" FAIL "$ORPH orphan rows"
step "04_foreign_keys" P -f $O/04_foreign_keys.sql
res "  links validated" "" "$(P -At -c "select count(*) filter (where convalidated)||'/'||count(*) from pg_constraint where contype='f' and connamespace='sap'::regnamespace")"
rm -rf $T/keys && mkdir -p $T/keys && cp $O/_model.json $O/links.py $O/apply_keys.py $T/keys/
step "apply_keys.py keys_test.csv" python3 $T/keys/apply_keys.py $B/keys_test.csv
step "07_real_keys" P -f $T/keys/07_real_keys.sql
res "  AAC1 key" "" "$(P -At -c "select pg_get_constraintdef(oid) from pg_constraint where conname='aac1_pkey'")"
step "06_security" P -f $O/06_security.sql
step "10_erp_schema" P -f $O/10_erp_schema.sql
step "11_erp_sync" P -f $O/11_erp_sync.sql
step "12_erp_security" P -f $O/12_erp_security.sql
step "13_migration_console" P -f $O/13_migration_console.sql
step "13 again (idempotent)" P -f $O/13_migration_console.sql
for co in AE01 SA01; do
  step "sync_company $co" P -c "CALL erp.sync_company('$co')"
  res "  rows written" "" "$(P -At -c "select sum(rows_written) from erp.sync_log where company_code='$co'")"
  BAD=$(P -At -c "select count(*) filter (where not ok)||' not ok of '||count(*) from erp.check_sync('$co')")
  [[ "$BAD" == 0\ * ]] && res "check_sync $co" PASS "$BAD" || res "check_sync $co" FAIL "$BAD"
  DEL=$(P -At -c "select count(*) from erp.check_deleted('$co')")
  [ "$DEL" = 0 ] && res "check_deleted $co" PASS "0 rows" || res "check_deleted $co" FAIL "$DEL"
done
P -c "TRUNCATE erp.sync_log"
for co in AE01 SA01; do P -c "CALL erp.sync_company('$co')"; done
W=$(P -At -c "select coalesce(sum(rows_written),0)||' rows in '||count(*)||' steps' from erp.sync_log")
[[ "$W" == 0\ * ]] && res "second sync writes 0 rows" PASS "$W" || res "second sync writes 0 rows" FAIL "$W"
P -f $T/fixtures.sql
psql "$DSN" -X -f $T/access_test.sql 2>&1 | grep -o 'PASS.*\|FAIL.*' | sed 's/^/  access: /'

# loader regression on the older test folders (shuffled columns, Arabic, quotes, binary, NCHAR/SMALLDECIMAL, data.ctl, extra column)
L="host=localhost port=5432 user=postgres dbname=mc_loader"
psql "$BASE dbname=postgres" -X -q -c "DROP DATABASE IF EXISTS mc_loader WITH (FORCE)" -c "CREATE DATABASE mc_loader"
for f in 00_setup.sql 01a_sap_standard.sql 01b_addon_udt.sql; do psql "$L" -X -q -v ON_ERROR_STOP=1 -f $O/$f >/dev/null 2>&1; done
psql "$L" -X -q -c "INSERT INTO sap._company VALUES ('AE01','SBO','x','AE','AED','free_zone',true),('SA01','SBO_KSA','y','SA','SAR','foreign',true)"
python3 $O/load_company.py --company SA01 --export $B/fakeexp --counts $B/fakeexp/row_counts.csv --dsn "$L password=$PGPASSWORD" >/dev/null
python3 $O/load_company.py --company AE01 --export $B/fake2 --columns $B/fake2/columns.csv --counts $B/fake2/row_counts.csv --dsn "$L password=$PGPASSWORD" >/dev/null
res "loader regression (fakeexp, fake2)" "" "$(psql "$L" -X -At -c "select string_agg(table_name||'='||status||' '||rows_loaded||'/'||rows_expected, '; ' order by table_name) from sap._load_log")"
res "  OCRD Arabic / OCPC binary" "" "$(psql "$L" -X -At -c "select (select \"CardName\" from sap.\"OCRD\" where \"CardCode\"='C0002')||' | '||(select encode(\"DiExpoCont\",'escape') from sap.\"OCPC\" where \"AbsEntry\"=1 limit 1)")"
psql "$BASE dbname=postgres" -X -q -c "DROP DATABASE IF EXISTS mc_loader WITH (FORCE)"
