ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = DOMIBUS_ADMIN;
-- *********************************************************************
-- Update Database Script
-- *********************************************************************
-- Change Log: src/main/resources/db/releases/5.0.8/partitioning/oracle/5.0.8-changelog-partitioning.xml
-- Ran at: 26/06/26 15:13
-- Against: null@offline:oracle?version=11.2.0&changeLogFile=target/liquibase/changelog-1.19-partitioning.oracle
-- Liquibase version: 4.17.0
-- *********************************************************************

-- Changeset src/main/resources/db/releases/5.0.8/partitioning/oracle/../../../../common/changelog-before-migration-statements-v2.xml::EDELIVERY-12286_stop_on_error_oracle::Gabriel Maier
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK;

-- Changeset src/main/resources/db/releases/5.0.8/partitioning/oracle/../../../../common/changelog-before-migration-statements-v2.xml::EDELIVERY-12287_assert_previous_migration_succeeded-v2-oracle::Gabriel Maier
create or replace PROCEDURE ASSERT_DB_VERSION_IS(in_expected_versions IN VARCHAR2) AS
    actual_version VARCHAR2(30);
    actual_creation_time TIMESTAMP;
    table_count INT;
    stmt  VARCHAR2(200);
    expected_versions VARCHAR2(50) := in_expected_versions;
BEGIN
    IF expected_versions = 'PreconditionDomibusVersionIs_not_set' OR expected_versions IS NULL THEN
        expected_versions := 'ignore';
    END IF;
    IF expected_versions = 'empty' THEN
        SELECT count(OBJECT_NAME)
        INTO table_count
        FROM USER_OBJECTS
        WHERE OBJECT_TYPE = 'TABLE';
        IF table_count > 0 THEN
                    RAISE_APPLICATION_ERROR(-20002, 'Domibus Failed Assertion Error: The schema should be empty to run this script file');
        END IF;
    ELSE
        IF expected_versions <> 'ignore' THEN
            stmt := 'SELECT V.VERSION, V.CREATION_TIME FROM TB_VERSION V ' ||
                    'INNER JOIN (SELECT MAX(V2.CREATION_TIME) AS MAX_CREATION_TIME FROM TB_VERSION V2) LAST_VERSION ON V.CREATION_TIME = LAST_VERSION.MAX_CREATION_TIME';
            execute IMMEDIATE stmt INTO actual_version, actual_creation_time;
            IF regexp_instr(expected_versions, '(^|,)\s*' || actual_version || '\s*(,|$)') = 0 THEN
                RAISE_APPLICATION_ERROR(-20001, 'Domibus Failed Assertion Error: Please upgrade first to version ' || expected_versions || '. The last successful upgrade was to version ' || actual_version || ' on ' || actual_creation_time);
            END IF;
        END IF;
    END IF;
END ASSERT_DB_VERSION_IS;
/

CALL ASSERT_DB_VERSION_IS('ignore');
/

/* Call this stored procedure to execute the statement contained in the parameter dmlStatement.
 In case the execution causes an error the statement that failed is rolled back.
 If the SQLCODE equals oraErrorCode then a warning message is logged and the error is ignored otherwise the error is rethrown with the SQLCODE code -20003  */
CREATE OR REPLACE PROCEDURE EXECUTE_AND_IGNORE_ERROR(dmlStatement IN VARCHAR2, oraErrorCode IN NUMBER) AS
BEGIN
    EXECUTE IMMEDIATE dmlStatement;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = oraErrorCode THEN
                DBMS_OUTPUT.PUT_LINE('Warning: Ignoring error [' || SQLERRM || '] after executing [' || dmlStatement || ']');
            ELSE
                RAISE_APPLICATION_ERROR(-20003, 'Unhandled exception [' || SQLERRM || ']');
            END IF;
END EXECUTE_AND_IGNORE_ERROR;
/

/* Extract the date from a tsid */
CREATE OR REPLACE FUNCTION tsid_to_date(tsid IN NUMBER)
    RETURN TIMESTAMP IS
    date_component NUMBER;
BEGIN
    SELECT MOD(FLOOR(tsid / POWER(2, 22)), POWER(2, 64)) AS unsigned_shifted INTO date_component FROM dual;
    -- Return the milliseconds that have passed since the default TSID epoch (midnight on 1st of January 2020)
    RETURN TIMESTAMP '2020-01-01 00:00:00.000' + NUMTODSINTERVAL(date_component / 1000, 'SECOND');
END;
/

/* Return 1 if TB_USER_MESSAGE is partitioned; 0 otherwise */
CREATE OR REPLACE FUNCTION is_partitioned
    RETURN NUMBER IS
    v_partitioned VARCHAR2(3);
BEGIN
    BEGIN
        SELECT partitioned
        INTO v_partitioned
        FROM user_tables
        WHERE table_name = 'TB_USER_MESSAGE';

        IF v_partitioned = 'YES' THEN
            RETURN 1;
        ELSE
            RETURN 0;
        END IF;

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Table doesn't exist or no access
                RETURN 0;
            WHEN TOO_MANY_ROWS THEN
                -- This shouldn't happen
                RETURN 0;
    END;
END is_partitioned;
/

-- Changeset src/main/resources/db/releases/5.0.8/partitioning/oracle/5.0.8-changelog-partitioning.xml::Partition tables::idragusa
CREATE OR REPLACE FUNCTION generate_partition_id(p_date IN DATE)
    RETURN NUMBER IS
    p_id NUMBER;
BEGIN
    DECLARE
        date_format CONSTANT STRING(10) := 'YYMMDDHH24';
    BEGIN
        SELECT to_number(to_char(p_date, date_format))
        INTO p_id
        FROM dual;
        RETURN p_id;
    END;
END;
/

CREATE OR REPLACE PROCEDURE PARTITION_TB_USER_MESSAGE
AS
BEGIN
    DECLARE
        p_id   NUMBER;
        p_name VARCHAR2(20);
        p_high NUMBER;
    BEGIN
        select generate_partition_id(CAST(SYSTIMESTAMP AT TIME ZONE 'UTC' AS DATE)+1/24) into p_id from dual;
        p_name := 'P' || p_id;
        p_high := p_id || '0000000000';
        --IDX_USER_MSG_MESSAGE_ID has to remain global because unique indexes cannot be locally partitioned unless the partition key is part of the index key (ORA-14196 on Oracle 19.19 and newer)
        EXECUTE IMMEDIATE 'ALTER TABLE TB_USER_MESSAGE MODIFY PARTITION BY RANGE (ID_PK) (PARTITION P1970 VALUES LESS THAN (220000000000000000), PARTITION ' || p_name || ' VALUES LESS THAN (' || p_high || ')) UPDATE INDEXES ( IDX_USER_MSG_ACTION_ID LOCAL, IDX_USER_MSG_AGREEMENT_ID LOCAL, IDX_USER_MSG_SERVICE_ID LOCAL, IDX_USER_MSG_MPC_ID LOCAL, IDX_FROM_ROLE_ID LOCAL, IDX_USER_MSG_TO_PARTY_ID LOCAL, IDX_TO_ROLE_ID LOCAL, IDX_USER_MSG_FROM_PARTY_ID LOCAL, IDX_TEST_MESSAGE LOCAL )';
    END;
END;
/

CREATE OR REPLACE PROCEDURE drop_partition (partition_name IN VARCHAR2) IS
   BEGIN
      execute immediate 'ALTER TABLE TB_USER_MESSAGE DROP PARTITION ' || partition_name || ' UPDATE INDEXES';
   END;
/

BEGIN
            PARTITION_TB_USER_MESSAGE();
            END;
/

ALTER TABLE TB_MESSAGE_ACKNW MODIFY PARTITION BY REFERENCE ( FK_MSG_ACK_USER_MSG );

ALTER TABLE TB_MESSAGE_ACKNW_PROP MODIFY PARTITION BY REFERENCE ( FK_MSG_ACK_PROP_MSG_ACK );

ALTER TABLE TB_SJ_MESSAGE_GROUP MODIFY PARTITION BY REFERENCE ( FK_MSG_FG_GROUP_UM ) UPDATE INDEXES ( IDX_SJ_MG_ROLE_FK LOCAL );

ALTER TABLE TB_SJ_MESSAGE_FRAGMENT MODIFY PARTITION BY REFERENCE ( FK_SJ_MSG_FG_USER_MSG ) UPDATE INDEXES ( IDX_FK_SJ_MSG_FG_GROUP LOCAL );

ALTER TABLE TB_USER_MESSAGE_LOG MODIFY PARTITION BY REFERENCE ( FK_MSG_LOG_MSG_ID ) UPDATE INDEXES ( IDX_USER_LOG_RECEIVED LOCAL, IDX_MESSAGE_LOG_TZ_OFFSET LOCAL, IDX_MSG_ARCHIVED LOCAL, IDX_MSG_EXPORTED LOCAL, IDX_MSG_ACKNOWLEDGED LOCAL, IDX_MSG_PROCESSING_TYPE LOCAL, IDX_MESSAGE_LOG_MSG_STATUS_ID LOCAL, IDX_MESSAGE_LOG_MSG_ROLE_ID LOCAL, IDX_MSG_LOG_NOTIF_STATUS_ID LOCAL );

ALTER TABLE TB_PART_INFO MODIFY PARTITION BY REFERENCE ( FK_PART_INFO_USER_MSG );

ALTER TABLE TB_PART_PROPERTIES MODIFY PARTITION BY REFERENCE ( FK_PART_PROPS_PART_INFO ) UPDATE INDEXES ( IDX_PART_PROPS_PART_PROP LOCAL );

ALTER TABLE TB_MESSAGE_PROPERTIES MODIFY PARTITION BY REFERENCE ( FK_MSG_PROPS_USER_MSG );

ALTER TABLE TB_USER_MESSAGE_RAW MODIFY PARTITION BY REFERENCE ( FK_MSG_RAW_USER_MSG );

ALTER TABLE TB_SIGNAL_MESSAGE MODIFY PARTITION BY REFERENCE ( FK_TB_SIGNAL_USER_MSG ) UPDATE INDEXES ( IDX_SIG_MESS_REF_TO_MESS_ID LOCAL);

ALTER TABLE TB_SIGNAL_MESSAGE_LOG MODIFY PARTITION BY REFERENCE ( FK_SIGNAL_LOG_SIGNAL_ID ) UPDATE INDEXES ( IDX_SIGNAL_LOG_MSG_STATUS_ID LOCAL, IDX_SIGNAL_LOG_MSG_ROLE_ID LOCAL, IDX_SIGNAL_LOG_RECEIVED LOCAL );

ALTER TABLE TB_RECEIPT MODIFY PARTITION BY REFERENCE ( FK_TB_RECEIPT_SIGNAL_MSG );

ALTER TABLE TB_SIGNAL_MESSAGE_RAW MODIFY PARTITION BY REFERENCE ( FK_SIGNAL_MSG_RAW_SIGNAL_MSG );

ALTER TABLE TB_SEND_ATTEMPT MODIFY PARTITION BY REFERENCE ( FK_SEND_ATTEMPT_USER_MSG );

ALTER TABLE TB_ERROR_LOG MODIFY PARTITION BY REFERENCE ( FK_ERROR_LOG_MSG_ID ) UPDATE INDEXES ( IDX_ERROR_LOG_MSH_ROLE_ID LOCAL, IDX_MESSAGE_IN_ERROR_ID LOCAL, IDX_SIGNAL_MESSAGE_ID LOCAL );

ALTER TABLE TB_USER_MESSAGE SET INTERVAL (10000000000);
