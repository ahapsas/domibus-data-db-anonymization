#!/bin/bash

# --- STEP 0: INTERACTIVE USER PROMPTS (STRICT ENFORCEMENT) ---
echo "=================================================="
echo "      Oracle Mock Production Data Importer        "
echo "=================================================="

# 1. Ask for the dump file directory path
read -p " Enter the absolute or relative directory path containing your .dmp file: " LOCAL_DIR
if [ -z "$LOCAL_DIR" ]; then
    echo " Error: Directory path cannot be empty. Script aborted."
    exit 1
fi

# 2. Ask for the dmp file name
read -p " Enter the exact name of the .dmp file (e.g., export.dmp): " DMP_FILE
if [ -z "$DMP_FILE" ]; then
    echo " Error: Dump file name cannot be empty. Script aborted."
    exit 1
fi

# Explicitly verify the file exists on the host filesystem before proceeding
if [ ! -f "$LOCAL_DIR/$DMP_FILE" ]; then
    echo " Error: File not found at '$LOCAL_DIR/$DMP_FILE'. Please verify the path and filename."
    exit 1
fi

# 3. Ask for the source schema name
read -p " Enter the ORIGINAL schema name inside the dump file: " SRC_SCHEMA
if [ -z "$SRC_SCHEMA" ]; then
    echo " Error: Original schema name cannot be empty. Script aborted."
    exit 1
fi

# Convert schema name to uppercase (Oracle default behavior)
SRC_SCHEMA=$(echo "$SRC_SCHEMA" | tr '[:lower:]' '[:upper:]')

echo "--------------------------------------------------"
echo " Configuration Verified & Locked:"
echo "   • Source File:  $LOCAL_DIR/$DMP_FILE"
echo "   • Source Schema: $SRC_SCHEMA"
echo "   • Target Schema: DOMIBUS_ADMIN"
echo "--------------------------------------------------"

# --- STEP 1: DYNAMIC DATA PUMP DIRECTORY DISCOVERY ---
echo " Fetching current Data Pump directory path..."
NEW_DP_DIR=$(docker exec -i domibus_prod_db sqlplus -L -s "sys/ProdSysPass123@//localhost:1521/FREEPDB1 as sysdba" <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON VERIFY OFF
SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';
EXIT;
EOF
)

# Clean up trailing carriage returns or spaces from the Oracle output
NEW_DP_DIR=$(echo "$NEW_DP_DIR" | tr -d '\r\n[:space:]')

if [ -z "$NEW_DP_DIR" ] || [ "$NEW_DP_DIR" == "SP2-0640:" ]; then
    echo " Error: Could not retrieve DATA_PUMP_DIR from container. Is the DB running?"
    exit 1
fi

echo " Active Container Path: $NEW_DP_DIR"

# --- STEP 2: TRANSFER SNAPSHOT FILE ---
echo " Copying dump file to container..."
docker cp "$LOCAL_DIR/$DMP_FILE" domibus_prod_db:"$NEW_DP_DIR/$DMP_FILE"

echo " Adjusting file permissions inside container (ROOT user)..."
docker exec -u 0 -i domibus_prod_db chown oracle:oinstall "$NEW_DP_DIR/$DMP_FILE"
docker exec -u 0 -i domibus_prod_db chmod 664 "$NEW_DP_DIR/$DMP_FILE"

# --- STEP 3: RESET TARGET DATABASE SCHEMA ---
echo " Re-creating DOMIBUS_ADMIN user to purge old constraints..."
docker exec -i domibus_prod_db sqlplus -L -s "sys/ProdSysPass123@//localhost:1521/FREEPDB1 as sysdba" <<EOF
SET FEEDBACK OFF VERIFY OFF
DECLARE
  user_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO user_count FROM dba_users WHERE username = 'DOMIBUS_ADMIN';
  IF user_count > 0 THEN
    EXECUTE IMMEDIATE 'DROP USER DOMIBUS_ADMIN CASCADE';
  END IF;
END;
/
CREATE USER DOMIBUS_ADMIN IDENTIFIED BY "DomibusPass123";
GRANT CONNECT, RESOURCE, DBA TO DOMIBUS_ADMIN;
GRANT UNLIMITED TABLESPACE TO DOMIBUS_ADMIN;
EXIT;
EOF

# --- STEP 4: EXECUTE ORA-COMPLIANT DATA IMPORT ---
echo " Importing data and mapping storage rules dynamically..."
docker exec -i domibus_prod_db impdp \"sys/ProdSysPass123@//localhost:1521/FREEPDB1 AS SYSDBA\" \
DUMPFILE="$DMP_FILE" \
LOGFILE=prod_test_import.log \
REMAP_SCHEMA="$SRC_SCHEMA":DOMIBUS_ADMIN \
TRANSFORM=SEGMENT_ATTRIBUTES:N

echo "--------------------------------------------------"
echo " Import Script Completed Successfully!"
echo "--------------------------------------------------"