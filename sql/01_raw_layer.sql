/* =============================================================================
   ATM Operations Analytics  -  RAW LAYER PHYSICAL IMPLEMENTATION
   Database:      ATMOpsAnalytics
   Schema:        raw
   Architecture:  raw -> stg -> core -> mart   
       ============================================================================= */

USE ATMOpsAnalytics;
GO

/* -----------------------------------------------------------------------------
   1. raw.atm_device_master
      Source file : atm_device_master.csv      
      Data Dict   : atm_device_master entity
      Grain       : 1 row per ATM device
   ----------------------------------------------------------------------------- */
IF OBJECT_ID('raw.atm_device_master','U') IS NULL
CREATE TABLE raw.atm_device_master (
    device_id        NVARCHAR(20)  NULL,
    acct_code        NVARCHAR(20)  NULL,
    acct_name        NVARCHAR(120) NULL,
    region           NVARCHAR(50)  NULL,
    deployment_type  NVARCHAR(30)  NULL,
    model            NVARCHAR(50)  NULL,
    install_dt       NVARCHAR(20)  NULL,
    decommission_dt  NVARCHAR(20)  NULL,
    status           NVARCHAR(20)  NULL,
    sla_tier         NVARCHAR(20)  NULL
);
GO

/* -----------------------------------------------------------------------------
   2. raw.sla_contract_reference
      Source file : sla_contract_reference.csv    
      Grain       : 1 SLA term per acct x type x priority x tier x period
   ----------------------------------------------------------------------------- */
IF OBJECT_ID('raw.sla_contract_reference','U') IS NULL
CREATE TABLE raw.sla_contract_reference (
    acct_code         NVARCHAR(20) NULL,
    sla_type          NVARCHAR(30) NULL,
    priority          NVARCHAR(10) NULL,
    sla_threshold     NVARCHAR(20) NULL,
    penalty_band      NVARCHAR(20) NULL,
    penalty_rate_egp  NVARCHAR(20) NULL,
    effective_start   NVARCHAR(20) NULL,
    effective_end     NVARCHAR(20) NULL,
    tier              NVARCHAR(20) NULL
);
GO

/* -----------------------------------------------------------------------------
   3. raw.incidents
      Source file : incidents.csv                
         Grain    : 1 row per incident lifecycle (raise -> restore -> close)
   ----------------------------------------------------------------------------- */
IF OBJECT_ID('raw.incidents','U') IS NULL
CREATE TABLE raw.incidents (
    inc_id           NVARCHAR(20) NULL,
    device_id        NVARCHAR(20) NULL,
    reported_src     NVARCHAR(30) NULL,
    raised_ts        NVARCHAR(30) NULL,
    ack_ts           NVARCHAR(30) NULL,
    restored_ts      NVARCHAR(30) NULL,
    closed_ts        NVARCHAR(30) NULL,
    priority         NVARCHAR(10) NULL,
    root_cause_code  NVARCHAR(20) NULL,
    fault_category   NVARCHAR(30) NULL,
    vendor           NVARCHAR(30) NULL
);
GO

/* -----------------------------------------------------------------------------
   4. raw.service_visits
      Source file : service_visits.csv            
         Grain    : 1 row per field-engineer visit against an incident
   ----------------------------------------------------------------------------- */
IF OBJECT_ID('raw.service_visits','U') IS NULL
CREATE TABLE raw.service_visits (
    visit_id        NVARCHAR(20)  NULL,
    inc_id          NVARCHAR(20)  NULL,
    device_id       NVARCHAR(20)  NULL,
    visit_seq       NVARCHAR(10)  NULL,
    engineer_id     NVARCHAR(20)  NULL,
    vendor          NVARCHAR(30)  NULL,
    dispatch_ts     NVARCHAR(30)  NULL,
    arrival_ts      NVARCHAR(30)  NULL,
    completion_ts   NVARCHAR(30)  NULL,
    visit_type      NVARCHAR(30)  NULL,
    visit_outcome   NVARCHAR(30)  NULL,
    parts_replaced  NVARCHAR(MAX) NULL
);
GO

/* -----------------------------------------------------------------------------
   5. raw.telemetry_events
      Source files: telemetry_events_YYYYMM.csv x24
      Data Dict   : telemetry_events entity
           Grain       : 1 row per device state/health event
         ----------------------------------------------------------------------------- */
IF OBJECT_ID('raw.telemetry_events','U') IS NULL
CREATE TABLE raw.telemetry_events (
    evt_id      NVARCHAR(30) NULL,
    device_id   NVARCHAR(20) NULL,
    evt_ts      NVARCHAR(30) NULL,
    state       NVARCHAR(20) NULL,
    evt_code    NVARCHAR(20) NULL,
    src         NVARCHAR(20) NULL
);
GO



   -----------------RELOAD / LOAD SECTION-full-reload pattern (idempotent)-----------------
  

DECLARE @landing NVARCHAR(260) = N'C:\ATMOps\landing\';   

-- 1. atm_device_master ---------------------------------------------------------
TRUNCATE TABLE raw.atm_device_master;
BULK INSERT raw.atm_device_master
FROM 'C:\ATMOps\landing\atm_device_master.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO

-- 2. sla_contract_reference ----------------------------------------------------
TRUNCATE TABLE raw.sla_contract_reference;
BULK INSERT raw.sla_contract_reference
FROM 'C:\ATMOps\landing\sla_contract_reference.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO

-- 3. incidents -----------------------------------------------------------------
TRUNCATE TABLE raw.incidents;
BULK INSERT raw.incidents
FROM 'C:\ATMOps\landing\incidents.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO

-- 4. service_visits ------------------------------------------------------------
TRUNCATE TABLE raw.service_visits;
BULK INSERT raw.service_visits
FROM 'C:\ATMOps\landing\service_visits.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO

-- 5. telemetry_events ----------------------------------------------------------
--    TRUNCATE ONCE, then append all 24 monthly files into the single raw table.
TRUNCATE TABLE raw.telemetry_events;
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202406.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202407.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202408.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202409.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202410.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202411.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202412.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202501.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202502.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202503.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202504.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202505.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202506.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202507.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202508.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202509.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202510.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202511.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202512.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202601.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202602.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202603.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202604.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO
BULK INSERT raw.telemetry_events
FROM 'C:\ATMOps\landing\telemetry_events_202605.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a',
      CODEPAGE = '65001', TABLOCK);
GO

/* =============================================================================
   POST-LOAD ROW-COUNT VALIDATION  (reconcile landed rows vs approved targets)
   ============================================================================= */
SELECT 'raw.atm_device_master' AS table_name,
COUNT(*) AS rows_loaded,
900 AS expected FROM raw.atm_device_master
UNION ALL SELECT 'raw.sla_contract_reference', COUNT(*), 84      FROM raw.sla_contract_reference
UNION ALL SELECT 'raw.incidents',             COUNT(*), 28107   FROM raw.incidents
UNION ALL SELECT 'raw.service_visits',        COUNT(*), 19100   FROM raw.service_visits
UNION ALL SELECT 'raw.telemetry_events',      COUNT(*), 2786490 FROM raw.telemetry_events;
GO
/* End of raw layer script. */
