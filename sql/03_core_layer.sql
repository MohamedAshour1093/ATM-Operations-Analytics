/* =============================================================================
   ATM Operations Analytics  -  CORE LAYER LOAD IMPLEMENTATION
   Database:      ATMOpsAnalytics
   Schema:        core
     Architecture:  raw -> stg -> core -> mart   
  
   ============================================================================= */

USE ATMOpsAnalytics;
GO


DECLARE @reporting_date DATE;
SELECT @reporting_date = CONVERT(DATE, MAX(evt_ts)) FROM stg.stg_telemetry_event;

IF @reporting_date IS NULL SELECT @reporting_date = CONVERT(DATE, MAX(raised_ts)) FROM stg.stg_incident;
GO


IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core;');
GO

IF OBJECT_ID('core.dim_date','U') IS NULL
CREATE TABLE core.dim_date (
    date_key      INT          NOT NULL PRIMARY KEY,   
    full_date     DATE         NOT NULL UNIQUE,
    [year]        SMALLINT     NOT NULL,
    [quarter]     TINYINT      NOT NULL,
    [month]       TINYINT      NOT NULL,
    month_name    NVARCHAR(12) NOT NULL,
    [day]         TINYINT      NOT NULL,
    day_of_week   TINYINT      NOT NULL,
    is_weekend    BIT          NOT NULL
);
GO

IF OBJECT_ID('core.dim_device','U') IS NULL
CREATE TABLE core.dim_device (
    device_key       INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    device_id        NVARCHAR(20)  NOT NULL UNIQUE,
    acct_code        NVARCHAR(10)  NOT NULL,
    acct_name        NVARCHAR(100) NOT NULL,
    region           NVARCHAR(50)  NOT NULL,
    deployment_type  NVARCHAR(20)  NOT NULL,
    model            NVARCHAR(50)  NOT NULL,
    install_dt       DATE          NOT NULL,
    decommission_dt  DATE          NULL,
    status           NVARCHAR(20)  NOT NULL,
    sla_tier         NVARCHAR(20)  NOT NULL,
    is_active        BIT           NOT NULL,            -- MS  business classification
    load_ts          DATETIME2(0)  NOT NULL             -- AUD
);
GO

IF OBJECT_ID('core.dim_sla_contract','U') IS NULL
CREATE TABLE core.dim_sla_contract (
    sla_contract_key INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    acct_code        NVARCHAR(10)  NOT NULL,
    sla_type         NVARCHAR(20)  NOT NULL,
    priority         NVARCHAR(10)  NOT NULL,
    sla_threshold    DECIMAL(6,2)  NOT NULL,
    penalty_band     NVARCHAR(20)  NOT NULL,
    penalty_rate_egp INT           NOT NULL,
    effective_start  DATE          NOT NULL,
    effective_end    DATE          NULL,
    tier             NVARCHAR(20)  NOT NULL,
    is_current       BIT           NOT NULL,           
    load_ts          DATETIME2(0)  NOT NULL             
);
GO

IF OBJECT_ID('core.fact_incident','U') IS NULL
CREATE TABLE core.fact_incident (
    incident_key     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    inc_id           NVARCHAR(20)  NOT NULL UNIQUE,      
    device_key       INT           NOT NULL,            -- FK -> dim_device
    raised_date_key  INT           NOT NULL,            -- FK -> dim_date (raised role)
    reported_src     NVARCHAR(30)  NOT NULL,
    raised_ts        DATETIME2(0)  NOT NULL,
    ack_ts           DATETIME2(0)  NULL,
    restored_ts      DATETIME2(0)  NULL,
    closed_ts        DATETIME2(0)  NULL,
    priority         NVARCHAR(10)  NOT NULL,
    root_cause_code  NVARCHAR(20)  NOT NULL,
    fault_category   NVARCHAR(30)  NOT NULL,
    vendor           NVARCHAR(30)  NOT NULL,             
    ttr_minutes      INT           NULL,                
    ack_minutes      INT           NULL,                
    load_ts          DATETIME2(0)  NOT NULL,            
    CONSTRAINT FK_factinc_device FOREIGN KEY (device_key)      REFERENCES core.dim_device(device_key),
    CONSTRAINT FK_factinc_date   FOREIGN KEY (raised_date_key) REFERENCES core.dim_date(date_key)
);
GO

IF OBJECT_ID('core.fact_service_visit','U') IS NULL
CREATE TABLE core.fact_service_visit (
    visit_key          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    visit_id           NVARCHAR(20)  NOT NULL UNIQUE,  
    inc_id             NVARCHAR(20)  NOT NULL,         
    device_key         INT           NOT NULL,         
    dispatch_date_key  INT           NOT NULL,         
    visit_seq          INT           NOT NULL,
    engineer_id        NVARCHAR(20)  NOT NULL,
    vendor             NVARCHAR(30)  NOT NULL,         
    dispatch_ts        DATETIME2(0)  NOT NULL,
    arrival_ts         DATETIME2(0)  NULL,
    completion_ts      DATETIME2(0)  NULL,
    visit_type         NVARCHAR(30)  NOT NULL,
    visit_outcome      NVARCHAR(30)  NOT NULL,
    parts_replaced     NVARCHAR(200) NULL,
    response_minutes   INT           NULL,             
    onsite_minutes     INT           NULL,             
    is_first_visit     BIT           NOT NULL,         
    load_ts            DATETIME2(0)  NOT NULL,         
    CONSTRAINT FK_factvis_device FOREIGN KEY (device_key)        REFERENCES core.dim_device(device_key),
    CONSTRAINT FK_factvis_date   FOREIGN KEY (dispatch_date_key) REFERENCES core.dim_date(date_key)
);
GO

IF OBJECT_ID('core.fact_telemetry_event','U') IS NULL
CREATE TABLE core.fact_telemetry_event (
    telemetry_key  BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY, 
    evt_id         NVARCHAR(30)  NOT NULL UNIQUE,      
    device_key     INT           NOT NULL,             
    evt_date_key   INT           NOT NULL,             
    evt_ts         DATETIME2(0)  NOT NULL,
    state          NVARCHAR(20)  NOT NULL,
    evt_code       NVARCHAR(20)  NULL,                 
    src            NVARCHAR(20)  NOT NULL,
    source_month   CHAR(6)       NOT NULL,             
    load_ts        DATETIME2(0)  NOT NULL,             
    CONSTRAINT FK_facttel_device FOREIGN KEY (device_key)   REFERENCES core.dim_device(device_key),
    CONSTRAINT FK_facttel_date   FOREIGN KEY (evt_date_key) REFERENCES core.dim_date(date_key)
);
GO


/* =============================================================================
                                 DIMENSION LOADS  
     ============================================================================= */

DECLARE @rep_date DATE;
SELECT @rep_date = CONVERT(DATE, MAX(evt_ts)) FROM stg.stg_telemetry_event;


DECLARE @min_dt DATE, @max_dt DATE;
SELECT @min_dt = MIN(d), @max_dt = MAX(d)
FROM (
    SELECT MIN(CONVERT(DATE,raised_ts))    AS d FROM stg.stg_incident
    UNION ALL SELECT MAX(CONVERT(DATE,COALESCE(closed_ts,restored_ts,ack_ts,raised_ts))) FROM stg.stg_incident
    UNION ALL SELECT MIN(CONVERT(DATE,dispatch_ts)) FROM stg.stg_service_visit
    UNION ALL SELECT MAX(CONVERT(DATE,COALESCE(completion_ts,arrival_ts,dispatch_ts))) FROM stg.stg_service_visit
    UNION ALL SELECT MIN(CONVERT(DATE,evt_ts)) FROM stg.stg_telemetry_event
    UNION ALL SELECT MAX(CONVERT(DATE,evt_ts)) FROM stg.stg_telemetry_event
) s;

SET @min_dt = DATEADD(DAY, -7,  @min_dt);  
SET @max_dt = DATEADD(DAY,  7,  @max_dt);  

TRUNCATE TABLE core.dim_date;

;WITH tally AS (
    SELECT TOP (DATEDIFF(DAY, @min_dt, @max_dt) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
cal AS (
    SELECT DATEADD(DAY, n, @min_dt) AS full_date FROM tally
)
INSERT core.dim_date (date_key, full_date, [year], [quarter], [month], month_name, [day], day_of_week, is_weekend)
SELECT
    CONVERT(INT, CONVERT(CHAR(8), full_date, 112))           AS date_key,        
    full_date,
    DATEPART(YEAR, full_date),
    DATEPART(QUARTER, full_date),
    DATEPART(MONTH, full_date),
    DATENAME(MONTH, full_date),
    DATEPART(DAY, full_date),
    DATEPART(WEEKDAY, full_date),
    CASE WHEN DATEPART(WEEKDAY, full_date)
              IN (DATEPART(WEEKDAY,'1900-01-06'), DATEPART(WEEKDAY,'1900-01-07'))  
         THEN 1 ELSE 0 END                                    AS is_weekend       
FROM cal;
GO


/* -----------------------------------------------------------------------------
   core.dim_device         stg.stg_device -> core.dim_device
   grain: 1 row per device
     ----------------------------------------------------------------------------- */
TRUNCATE TABLE core.fact_telemetry_event;   
TRUNCATE TABLE core.fact_service_visit;
TRUNCATE TABLE core.fact_incident;
GO
DELETE FROM core.dim_device;
DBCC CHECKIDENT ('core.dim_device', RESEED, 0) WITH NO_INFOMSGS;
GO

DECLARE @rep_date DATE;
SELECT @rep_date = CONVERT(DATE, MAX(evt_ts)) FROM stg.stg_telemetry_event;

INSERT core.dim_device (device_id, acct_code, acct_name, region, deployment_type, model,
                        install_dt, decommission_dt, status, sla_tier, is_active, load_ts)
SELECT
    d.device_id,
    d.acct_code,
    d.acct_name,
    d.region,
    d.deployment_type,
    d.model,
    d.install_dt,
    d.decommission_dt,
    d.status,
    d.sla_tier,
    CASE WHEN d.decommission_dt IS NULL AND d.status = 'Active'
         THEN 1 ELSE 0 END                AS is_active,     
    SYSUTCDATETIME()                       AS load_ts
FROM stg.stg_device d;
GO


/* -----------------------------------------------------------------------------
  core.dim_sla_contract     stg.stg_sla_contract -> core.dim_sla_contract
   grain: 1 SLA term per acct x type x priority x tier x period 
      ----------------------------------------------------------------------------- */
DELETE FROM core.dim_sla_contract;
DBCC CHECKIDENT ('core.dim_sla_contract', RESEED, 0) WITH NO_INFOMSGS;
GO

DECLARE @rep_date DATE;
SELECT @rep_date = CONVERT(DATE, MAX(evt_ts)) FROM stg.stg_telemetry_event;

INSERT core.dim_sla_contract (acct_code, sla_type, priority, sla_threshold, penalty_band,
                              penalty_rate_egp, effective_start, effective_end, tier, is_current, load_ts)
SELECT
    s.acct_code,
    s.sla_type,
    s.priority,
    s.sla_threshold,
    s.penalty_band,
    s.penalty_rate_egp,
    s.effective_start,
    s.effective_end,
    s.tier,
    CASE WHEN s.effective_end IS NULL OR s.effective_end >= @rep_date
         THEN 1 ELSE 0 END                 AS is_current,   
    SYSUTCDATETIME()                        AS load_ts
FROM stg.stg_sla_contract s;
GO




/* -----------------------------------------------------------------------------
   3.1  core.fact_incident    stg.stg_incident -> core.fact_incident
   grain: 1 row per incident 
      ----------------------------------------------------------------------------- */

-- orphan capture (RELATIONSHIP RESOLUTION failure)
INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'core.fact_incident', i.inc_id, 'ORPHAN device_id not in dim_device',
       CONCAT_WS('|', i.inc_id, i.device_id)
FROM stg.stg_incident i
LEFT JOIN core.dim_device d ON d.device_id = i.device_id
WHERE d.device_key IS NULL;

INSERT core.fact_incident (inc_id, device_key, raised_date_key, reported_src, raised_ts,
                           ack_ts, restored_ts, closed_ts, priority, root_cause_code,
                           fault_category, vendor, ttr_minutes, ack_minutes, load_ts)
SELECT
    i.inc_id,
    d.device_key,                                                      
    CONVERT(INT, CONVERT(CHAR(8), i.raised_ts, 112))   AS raised_date_key, 
    i.reported_src,
    i.raised_ts,
    i.ack_ts,
    i.restored_ts,
    i.closed_ts,
    i.priority,
    i.root_cause_code,
    i.fault_category,
    i.vendor,
    CASE WHEN i.restored_ts IS NOT NULL
         THEN DATEDIFF(MINUTE, i.raised_ts, i.restored_ts) END AS ttr_minutes,  
    CASE WHEN i.ack_ts IS NOT NULL
         THEN DATEDIFF(MINUTE, i.raised_ts, i.ack_ts) END      AS ack_minutes,  
    SYSUTCDATETIME()
FROM stg.stg_incident i
INNER JOIN core.dim_device d ON d.device_id = i.device_id;              
GO


/* -----------------------------------------------------------------------------
   core.fact_service_visit    stg.stg_service_visit -> core.fact_service_visit
   grain: 1 row per engineer visit 
   
   ----------------------------------------------------------------------------- */
INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'core.fact_service_visit', v.visit_id, 'ORPHAN device_id not in dim_device',
       CONCAT_WS('|', v.visit_id, v.device_id)
FROM stg.stg_service_visit v
LEFT JOIN core.dim_device d ON d.device_id = v.device_id
WHERE d.device_key IS NULL;

INSERT core.fact_service_visit (visit_id, inc_id, device_key, dispatch_date_key, visit_seq,
                                engineer_id, vendor, dispatch_ts, arrival_ts, completion_ts,
                                visit_type, visit_outcome, parts_replaced, response_minutes,
                                onsite_minutes, is_first_visit, load_ts)
SELECT
    v.visit_id,
    v.inc_id,                                                           
    d.device_key,                                                        
    CONVERT(INT, CONVERT(CHAR(8), v.dispatch_ts, 112)) AS dispatch_date_key,
    v.visit_seq,
    v.engineer_id,
    v.vendor,
    v.dispatch_ts,
    v.arrival_ts,
    v.completion_ts,
    v.visit_type,
    v.visit_outcome,
    v.parts_replaced,
    CASE WHEN v.arrival_ts IS NOT NULL
         THEN DATEDIFF(MINUTE, v.dispatch_ts, v.arrival_ts) END  AS response_minutes,  
    CASE WHEN v.completion_ts IS NOT NULL AND v.arrival_ts IS NOT NULL
         THEN DATEDIFF(MINUTE, v.arrival_ts, v.completion_ts) END AS onsite_minutes,   
    CASE WHEN v.visit_seq = 1 THEN 1 ELSE 0 END               AS is_first_visit,       
    SYSUTCDATETIME()
FROM stg.stg_service_visit v
INNER JOIN core.dim_device d ON d.device_id = v.device_id;             
GO


/* -----------------------------------------------------------------------------
   3.3  core.fact_telemetry_event  stg.stg_telemetry_event -> core.fact_telemetry_event
   grain: 1 row per device event 
  
   ----------------------------------------------------------------------------- */
INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'core.fact_telemetry_event', t.evt_id, 'ORPHAN device_id not in dim_device',
       CONCAT_WS('|', t.evt_id, t.device_id)
FROM stg.stg_telemetry_event t
LEFT JOIN core.dim_device d ON d.device_id = t.device_id
WHERE d.device_key IS NULL;

INSERT core.fact_telemetry_event (evt_id, device_key, evt_date_key, evt_ts, state,
                                  evt_code, src, source_month, load_ts)
SELECT
    t.evt_id,
    d.device_key,                                                      
    CONVERT(INT, CONVERT(CHAR(8), t.evt_ts, 112))  AS evt_date_key,    
    t.evt_ts,
    t.state,
    t.evt_code,
    t.src,
    t.source_month,                                                 
    SYSUTCDATETIME()
FROM stg.stg_telemetry_event t
INNER JOIN core.dim_device d ON d.device_id = t.device_id;          
GO


/* =============================================================================
   RECONCILIATION CONTROLS
  
   ============================================================================= */

-- 1 row-count reconciliation (facts + device/sla dims)
SELECT 'dim_device'           AS core_table,
       (SELECT COUNT(*) FROM stg.stg_device)              AS stg_rows,
       (SELECT COUNT(*) FROM core.dim_device)             AS core_rows,
       0                                                  AS core_orphan_rejects
UNION ALL SELECT 'dim_sla_contract',
       (SELECT COUNT(*) FROM stg.stg_sla_contract),
       (SELECT COUNT(*) FROM core.dim_sla_contract), 0
UNION ALL SELECT 'fact_incident',
       (SELECT COUNT(*) FROM stg.stg_incident),
       (SELECT COUNT(*) FROM core.fact_incident),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='core.fact_incident')
UNION ALL SELECT 'fact_service_visit',
       (SELECT COUNT(*) FROM stg.stg_service_visit),
       (SELECT COUNT(*) FROM core.fact_service_visit),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='core.fact_service_visit')
UNION ALL SELECT 'fact_telemetry_event',
       (SELECT COUNT(*) FROM stg.stg_telemetry_event),
       (SELECT COUNT(*) FROM core.fact_telemetry_event),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='core.fact_telemetry_event');

-- 2 dim_date coverage check (must envelope every fact date; expect 0 gaps)
SELECT 'fact_incident'      AS fact_table,
       SUM(CASE WHEN dd.date_key IS NULL THEN 1 ELSE 0 END) AS unmatched_date_keys
FROM core.fact_incident f LEFT JOIN core.dim_date dd ON dd.date_key = f.raised_date_key
UNION ALL
SELECT 'fact_service_visit',
       SUM(CASE WHEN dd.date_key IS NULL THEN 1 ELSE 0 END)
FROM core.fact_service_visit f LEFT JOIN core.dim_date dd ON dd.date_key = f.dispatch_date_key
UNION ALL
SELECT 'fact_telemetry_event',
       SUM(CASE WHEN dd.date_key IS NULL THEN 1 ELSE 0 END)
FROM core.fact_telemetry_event f LEFT JOIN core.dim_date dd ON dd.date_key = f.evt_date_key;

-- 3 referential integrity: every fact device_key resolves (expect 0)
SELECT 'fact_incident'      AS fact_table,
       SUM(CASE WHEN d.device_key IS NULL THEN 1 ELSE 0 END) AS unmatched_device_keys
FROM core.fact_incident f LEFT JOIN core.dim_device d ON d.device_key = f.device_key
UNION ALL
SELECT 'fact_service_visit',
       SUM(CASE WHEN d.device_key IS NULL THEN 1 ELSE 0 END)
FROM core.fact_service_visit f LEFT JOIN core.dim_device d ON d.device_key = f.device_key
UNION ALL
SELECT 'fact_telemetry_event',
       SUM(CASE WHEN d.device_key IS NULL THEN 1 ELSE 0 END)
FROM core.fact_telemetry_event f LEFT JOIN core.dim_device d ON d.device_key = f.device_key;

-- 4 grain / uniqueness sentinels (each business key unique = grain held)
SELECT 'dim_device.device_id'        AS grain_check, COUNT(*)-COUNT(DISTINCT device_id) AS dup_count FROM core.dim_device
UNION ALL SELECT 'fact_incident.inc_id',        COUNT(*)-COUNT(DISTINCT inc_id)   FROM core.fact_incident
UNION ALL SELECT 'fact_service_visit.visit_id', COUNT(*)-COUNT(DISTINCT visit_id) FROM core.fact_service_visit
UNION ALL SELECT 'fact_telemetry_event.evt_id', COUNT(*)-COUNT(DISTINCT evt_id)   FROM core.fact_telemetry_event;
GO

