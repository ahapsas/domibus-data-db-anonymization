#!/bin/bash

# Exit instantly if any step fails
set -e

echo "=================================================="
echo " STARTING AUTOMATED DATA PUMP EXPORT RUN"
echo "=================================================="

# 0. Prep the physical OS directory inside the container as the root user
echo " Preparing OS directory permissions..."
docker exec -u 0 domibus_anon_db mkdir -p /opt/oracle/exports
docker exec -u 0 domibus_anon_db chmod 777 /opt/oracle/exports

# 1. Configure the database directory
echo "⚙️ Configuring Oracle directory pointers..."
docker exec -i domibus_anon_db sqlplus -S system/AnonSysPass123@FREE <<EOF
CREATE OR REPLACE DIRECTORY DATA_PUMP_DIR AS '/opt/oracle/exports';
ALTER SESSION SET CONTAINER = FREEPDB1;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO DOMIBUS_ADMIN;
GRANT DATAPUMP_EXP_FULL_DATABASE TO DOMIBUS_ADMIN;
EXIT;
EOF

# 2. Run the Data Pump Export
echo " ./Executing native command line expdp engine..."
docker exec -i domibus_anon_db expdp DOMIBUS_ADMIN/DomibusPass123@FREEPDB1 \
  SCHEMAS=DOMIBUS_ADMIN \
  DIRECTORY=DATA_PUMP_DIR \
  DUMPFILE=domibus_anonymized_sandbox.dmp \
  LOGFILE=export_sandbox.log \
  REUSE_DUMPFILES=YES

# 3. Fix permissions and flatten the folder structure!
echo "🧹 Cleaning up folder structure and fixing OS permissions..."

# Move the dump and log files out of the Oracle GUID folder and into the root exports folder
docker exec -u 0 domibus_anon_db sh -c 'mv /opt/oracle/exports/*/* /opt/oracle/exports/ 2>/dev/null || true'

# Change permissions so your host user has full read/write/delete access
docker exec -u 0 domibus_anon_db chmod -R 777 /opt/oracle/exports/

# Delete the empty Oracle GUID folder to keep it clean
docker exec -u 0 domibus_anon_db sh -c 'find /opt/oracle/exports/ -mindepth 1 -type d -empty -delete'

echo "======================================================================"
echo " SUCCESS: Your clean dump file is ready in .docker/exports/ directory!"
echo "======================================================================"