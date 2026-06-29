#!/bin/bash

# --- STEP 0: LOAD ENVIRONMENT VARIABLES ---
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    echo "⚙️ Loading configuration from $ENV_FILE..."
    source "$ENV_FILE"
else
    echo "❌ Error: Configuration file $ENV_FILE not found!"
    exit 1
fi

# Set dynamic variables
HOURS=${HOURS_TO_SYNC:-10}
INT_SYS_PROD_SQL="sys/ProdSysPass123@//localhost:1521/$PDB_NAME as sysdba"
INT_SYS_ANON_SQL="sys/AnonSysPass123@//localhost:1521/$PDB_NAME as sysdba"

# Data Pump specific connection strings
EXPDP_CONN="sys/ProdSysPass123@//localhost:1521/$PDB_NAME"
IMPDP_CONN="sys/AnonSysPass123@//localhost:1521/$PDB_NAME"

# Dump File & Log Configuration
DMP_FILE="domibus_migration.dmp"
EXPORT_LOG="domibus_export.log"
IMPORT_LOG="domibus_import.log"

echo "--------------------------------------------------"
echo "🚀 Starting Data Migration & Anonymization Pipeline"
echo "--------------------------------------------------"

# --- STEP 1: GENERATE PARAMETER FILE INSIDE PROD ---
echo "📦 Generating Data Pump parameter file inside container..."

docker exec -i domibus_prod_db bash -c "
cat <<EOF > /tmp/full.par
LOGFILE=$EXPORT_LOG
REUSE_DUMPFILES=YES
EOF
"

# Dynamically append targeted tables/partitions
docker exec -i domibus_prod_db sqlplus -L -s "$INT_SYS_PROD_SQL" <<EOF | docker exec -i domibus_prod_db bash -c "grep -E '^TABLES=' >> /tmp/full.par"
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON VERIFY OFF

-- Dynamic Partitions
SELECT 'TABLES=' || table_owner || '.' || table_name || ':' || partition_name FROM ALL_TAB_PARTITIONS WHERE PARTITION_NAME IN(
SELECT partition_name FROM(
SELECT table_owner, table_name, partition_name, ROW_NUMBER() OVER (PARTITION BY table_name ORDER BY partition_position DESC) as rank
FROM all_tab_partitions WHERE table_owner = '$DB_USER' and table_name = 'TB_USER_MESSAGE') WHERE RANK <=$HOURS UNION ALL SELECT 'P1970' FROM DUAL);

-- Static Tables
SELECT 'TABLES=' || owner || '.' || table_name
FROM all_tables WHERE owner = '$DB_USER' AND partitioned = 'NO';
EXIT;
EOF

# --- STEP 2, 3 & 4: TRANSFER AND IMPORT DATA ---
echo "🔄 Finding default Data Pump directories..."

# Find the exact path where Oracle generated the dmp file in Prod
PROD_DMP_DIR=$(docker exec -i domibus_prod_db sqlplus -L -s "$INT_SYS_PROD_SQL" <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';
EXIT;
EOF
)
PROD_DMP_DIR=$(echo "$PROD_DMP_DIR" | tr -d '\r\n[:space:]')

echo "📤 Exporting raw data from Production DB Container (domibus_prod_db)..."
docker exec -i domibus_prod_db expdp \"$EXPDP_CONN AS SYSDBA\" PARFILE=/tmp/full.par DUMPFILE="$DMP_FILE"

echo "🚚 Transferring dump file between containers..."
docker cp domibus_prod_db:"$PROD_DMP_DIR"/"$DMP_FILE" ./"$DMP_FILE"

# Find the exact path for the Anon Container
ANON_DMP_DIR=$(docker exec -i domibus_anon_db sqlplus -L -s "$INT_SYS_ANON_SQL" <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';
EXIT;
EOF
)
ANON_DMP_DIR=$(echo "$ANON_DMP_DIR" | tr -d '\r\n[:space:]')

docker cp ./"$DMP_FILE" domibus_anon_db:"$ANON_DMP_DIR"/"$DMP_FILE"
rm ./"$DMP_FILE"

# Fix ownership and permissions inside the target container as ROOT user (-u 0)
docker exec -u 0 -i domibus_anon_db chown oracle:oinstall "$ANON_DMP_DIR"/"$DMP_FILE"
docker exec -u 0 -i domibus_anon_db chmod 664 "$ANON_DMP_DIR"/"$DMP_FILE"

echo "🧹 Re-creating Schema User in Anon DB to completely clear metadata..."
# Κάνουμε drop cascade τον χρήστη και τον ξαναδημιουργούμε με τα απαραίτητα βασικά privileges
docker exec -i domibus_anon_db sqlplus -L -s "$INT_SYS_ANON_SQL" <<EOF
SET FEEDBACK OFF VERIFY OFF
declare
  user_count number;
begin
  select count(*) into user_count from dba_users where username = UPPER('$DB_USER');
  if user_count > 0 then
    execute immediate 'DROP USER ' || UPPER('$DB_USER') || ' CASCADE';
  end if;
end;
/
CREATE USER $DB_USER IDENTIFIED BY "$DB_PASS";
GRANT CONNECT, RESOURCE, DBA TO $DB_USER;
GRANT UNLIMITED TABLESPACE TO $DB_USER;
EXIT;
EOF

echo "📥 Importing data into Anonymization Sandbox DB (domibus_anon_db)..."
# Επειδή ο χρήστης είναι πλέον άδειος, το impdp θα δημιουργήσει σωστά όλα τα tables/partitions χωρίς συγκρούσεις
docker exec -i domibus_anon_db impdp \"$IMPDP_CONN AS SYSDBA\" DUMPFILE="$DMP_FILE" LOGFILE="$IMPORT_LOG"

# --- STEP 5: EXECUTE PYTHON ANONYMIZATION PIPELINE ---
echo "🧠 Triggering Python Anonymization Engine on Host Port $ANON_PORT..."
cd docker

if [ -d ".venv" ]; then
    source .venv/bin/activate
fi

export DB_TARGET_PORT=$ANON_PORT
export DB_TARGET_USER=$DB_USER
export DB_TARGET_PASS=$DB_PASS
export DB_TARGET_PDB=$PDB_NAME

python anonymizer.py

cd ..

echo "--------------------------------------------------"
echo "✅ Pipeline Executed Successfully!"
echo "--------------------------------------------------"