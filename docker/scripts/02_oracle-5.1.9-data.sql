ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = DOMIBUS_ADMIN;
-- *********************************************************************
-- Update Database Script
-- *********************************************************************
-- Change Log: src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml
-- Ran at: 5/05/26 15:08
-- Against: null@offline:oracle?version=11.2.0&changeLogFile=target/liquibase/changelog-1.18-data.oracle
-- Liquibase version: 4.17.0
-- *********************************************************************

-- Changeset src/main/resources/db/releases/5.1.9/../../common/changelog-before-migration-statements-v2.xml::EDELIVERY-12286_stop_on_error_oracle::Gabriel Maier
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK;

-- Changeset src/main/resources/db/releases/5.1.9/../../common/changelog-before-migration-statements-v2.xml::EDELIVERY-12287_assert_previous_migration_succeeded-v2-oracle::Gabriel Maier
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

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::EDELIVERY-2144_1::thomas dussart
INSERT INTO TB_USER_ROLE (ID_PK, ROLE_NAME) VALUES ('197001010000000001', 'ROLE_ADMIN');

INSERT INTO TB_USER_ROLE (ID_PK, ROLE_NAME) VALUES ('197001010000000002', 'ROLE_USER');

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::EDELIVERY-7368::ionperpegel
INSERT INTO TB_D_MSH_ROLE (ID_PK, ROLE) VALUES ('197001010000000001', 'SENDING');

INSERT INTO TB_D_MSH_ROLE (ID_PK, ROLE) VALUES ('197001010000000002', 'RECEIVING');

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::EDELIVERY-7836-insert::idragusa
INSERT INTO TB_USER_MESSAGE (ID_PK, MSH_ROLE_ID_FK) VALUES ('19700101', '197001010000000001');

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::EDELIVERY-8503_2::ion perpegel
INSERT INTO TB_LOCK (ID_PK, LOCK_KEY) VALUES ('197001010000000001', 'bootstrap-synchronization.lock');

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::EDELIVERY-9451::ion perpegel
INSERT INTO TB_LOCK (ID_PK, LOCK_KEY) VALUES ('197001010000000002', 'scheduler-synchronization.lock');

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::insert_last_pk_in_TB_EARCHIVE_START::gautifr
INSERT INTO TB_EARCHIVE_START (ID_PK, LAST_PK_USER_MESSAGE, DESCRIPTION) VALUES ('1', '000101000000000000', 'START ID_PK FOR CONTINUOUS EXPORT');

INSERT INTO TB_EARCHIVE_START (ID_PK, LAST_PK_USER_MESSAGE, DESCRIPTION) VALUES ('2', '000101000000000000', 'START ID_PK FOR SANITY EXPORT');

-- Changeset src/main/resources/db/releases/5.1.9/5.1.9-changelog-data.xml::EDELIVERY-11903::Cosmin Baciu
INSERT INTO TB_LOCK (ID_PK, LOCK_KEY) VALUES ('197001010000000003', 'keystore-synchronization.lock');

-- Changeset src/main/resources/db/releases/5.1.9/../../common/changelog-version-inserts.xml::EDELIVERY-7668-oracle::Catalin Enache
MERGE INTO TB_VERSION
            USING dual
            ON (VERSION = '5.1.9')
            WHEN MATCHED
                THEN
                UPDATE
                SET BUILD_TIME    = '2026-05-05 13:08',
                    CREATION_TIME = SYS_EXTRACT_UTC(CURRENT_TIMESTAMP)
            WHEN NOT MATCHED
                THEN
                INSERT (VERSION, BUILD_TIME, CREATION_TIME)
                VALUES ('5.1.9', '2026-05-05 13:08', SYS_EXTRACT_UTC(CURRENT_TIMESTAMP));
