/* =============================================================================
   ATM Operations Analytics  -  STAGING LAYER PHYSICAL IMPLEMENTATION

   Database:      ATMOpsAnalytics
   Schema:        stg
   Architecture:  raw -> stg -> core -> mart   
  
   ============================================================================= */

USE ATMOpsAnalytics;
GO

/* =============================================================================
   
 SECTION 0 - SCHEMA + SHARED DATA-QUALITY REJECT SET
   Creates the STG schema and shared reject table for DQ failures


   ============================================================================= */
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg;');
GO

IF OBJECT_ID('stg.dq_reject','U') IS NULL
CREATE TABLE stg.dq_reject (
    reject_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    source_table  NVARCHAR(40)  NOT NULL,   
    business_key  NVARCHAR(60)  NULL,       
    reject_rule   NVARCHAR(80)  NOT NULL,   
    raw_payload   NVARCHAR(MAX) NULL,       
    rejected_ts   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO


/* =============================================================================
   SECTION 1  -  stg.stg_device      
   raw.atm_device_master  ->  stg.stg_device
   grain: 1 row per device 
   
   ============================================================================= */
IF OBJECT_ID('stg.stg_device','U') IS NULL
CREATE TABLE stg.stg_device (
    device_id        NVARCHAR(20)  NOT NULL,  
    acct_code        NVARCHAR(10)  NOT NULL,  
    acct_name        NVARCHAR(100) NULL,      
    region           NVARCHAR(50)  NULL,      
    deployment_type  NVARCHAR(20)  NULL,      
    model            NVARCHAR(50)  NULL,      
    install_dt       DATE          NOT NULL,  
    decommission_dt  DATE          NULL,      
    status           NVARCHAR(20)  NULL,      
    sla_tier         NVARCHAR(20)  NULL       
);
GO

IF OBJECT_ID('tempdb..#dev') IS NOT NULL DROP TABLE #dev;
SELECT
    device_id_std        = UPPER(LTRIM(RTRIM(device_id))),
    acct_code_std        = UPPER(LTRIM(RTRIM(acct_code))),
    acct_name_std        = LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(acct_name,'  ',' '),'  ',' '),'  ',' '))),
    region_canon         = CASE UPPER(LTRIM(RTRIM(region)))
                              WHEN 'ALEXANDRIA' THEN 'Alexandria' WHEN 'ASWAN' THEN 'Aswan'
                              WHEN 'ASYUT' THEN 'Asyut'           WHEN 'BEHEIRA' THEN 'Beheira'
                              WHEN 'CAIRO' THEN 'Cairo'           WHEN 'DAKAHLIA' THEN 'Dakahlia'
                              WHEN 'GHARBIA' THEN 'Gharbia'       WHEN 'GIZA' THEN 'Giza'
                              WHEN 'ISMAILIA' THEN 'Ismailia'     WHEN 'LUXOR' THEN 'Luxor'
                              WHEN 'MATROUH' THEN 'Matrouh'       WHEN 'MINYA' THEN 'Minya'
                              WHEN 'NEW VALLEY' THEN 'New Valley' WHEN 'PORT SAID' THEN 'Port Said'
                              WHEN 'QALYUBIA' THEN 'Qalyubia'     WHEN 'QENA' THEN 'Qena'
                              WHEN 'RED SEA' THEN 'Red Sea'       WHEN 'SHARQIA' THEN 'Sharqia'
                              WHEN 'SOHAG' THEN 'Sohag'           WHEN 'SOUTH SINAI' THEN 'South Sinai'
                              WHEN 'SUEZ' THEN 'Suez'
                              ELSE NULL END,                      
    deployment_std       = LTRIM(RTRIM(deployment_type)),
    model_std            = LTRIM(RTRIM(model)),
    status_std           = LTRIM(RTRIM(status)),
    sla_tier_std         = LTRIM(RTRIM(sla_tier)),
    install_dt_typed     = TRY_CONVERT(DATE, LTRIM(RTRIM(install_dt)), 23),
    decom_dt_typed       = TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(decommission_dt)),''), 23),
    dup_rn               = COUNT(*) OVER (PARTITION BY UPPER(LTRIM(RTRIM(device_id)))),
    raw_payload          = CONCAT_WS('|', device_id, acct_code, acct_name, region,
                                     deployment_type, model, install_dt, decommission_dt, status, sla_tier)
INTO #dev
FROM raw.atm_device_master;

-- structural rejects
INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'raw.atm_device_master', device_id_std,
       CASE
         WHEN device_id_std IS NULL OR device_id_std = '' THEN 'BLANK_BUSINESS_KEY device_id'
         WHEN dup_rn > 1                                  THEN 'DUPLICATE_BUSINESS_KEY device_id'
         WHEN install_dt_typed IS NULL                    THEN 'UNCONVERTIBLE install_dt (NOT NULL)'
         WHEN decom_dt_typed IS NOT NULL
              AND decom_dt_typed < install_dt_typed       THEN 'CHRONOLOGY decommission_dt < install_dt'
       END, raw_payload
FROM #dev
WHERE device_id_std IS NULL OR device_id_std = ''
   OR dup_rn > 1
   OR install_dt_typed IS NULL
   OR (decom_dt_typed IS NOT NULL AND decom_dt_typed < install_dt_typed);

-- load valid rows
TRUNCATE TABLE stg.stg_device;
INSERT stg.stg_device (device_id, acct_code, acct_name, region, deployment_type,
                       model, install_dt, decommission_dt, status, sla_tier)
SELECT device_id_std, acct_code_std, acct_name_std, region_canon, deployment_std,
       model_std, install_dt_typed, decom_dt_typed, status_std, sla_tier_std
FROM #dev
WHERE device_id_std IS NOT NULL AND device_id_std <> ''
  AND dup_rn = 1
  AND install_dt_typed IS NOT NULL
  AND (decom_dt_typed IS NULL OR decom_dt_typed >= install_dt_typed);
GO


/* =============================================================================
   SECTION 2  -  stg.stg_sla_contract     
   raw.sla_contract_reference -> stg.stg_sla_contract
   grain: 1 SLA term per acct x type x priority x tier x period 

   ============================================================================= */
IF OBJECT_ID('stg.stg_sla_contract','U') IS NULL
CREATE TABLE stg.stg_sla_contract (
    acct_code         NVARCHAR(10)  NOT NULL, 
    sla_type          NVARCHAR(20)  NULL,     
    priority          NVARCHAR(10)  NULL,     
    sla_threshold     DECIMAL(6,2)  NOT NULL, 
    penalty_band      NVARCHAR(20)  NULL,     
    penalty_rate_egp  INT           NOT NULL, 
    effective_start   DATE          NOT NULL, 
    effective_end     DATE          NULL,     
    tier              NVARCHAR(20)  NULL      
);
GO

IF OBJECT_ID('tempdb..#sla') IS NOT NULL DROP TABLE #sla;
SELECT
    acct_code_std   = UPPER(LTRIM(RTRIM(acct_code))),
    sla_type_std    = LTRIM(RTRIM(sla_type)),
    priority_std    = UPPER(LTRIM(RTRIM(priority))),
    threshold_typed = TRY_CONVERT(DECIMAL(6,2), LTRIM(RTRIM(sla_threshold))),
    penalty_band_std= LTRIM(RTRIM(penalty_band)),
    rate_typed      = TRY_CONVERT(INT, LTRIM(RTRIM(penalty_rate_egp))),
    eff_start_typed = TRY_CONVERT(DATE, LTRIM(RTRIM(effective_start)), 23),
    eff_end_typed   = TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(effective_end)),''), 23),
    tier_std        = LTRIM(RTRIM(tier)),
    raw_payload     = CONCAT_WS('|', acct_code, sla_type, priority, sla_threshold,
                                penalty_band, penalty_rate_egp, effective_start, effective_end, tier)
INTO #sla
FROM raw.sla_contract_reference;

INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'raw.sla_contract_reference',
       CONCAT_WS('~', acct_code_std, sla_type_std, priority_std, tier_std),
       CASE
         WHEN acct_code_std IS NULL OR acct_code_std=''      THEN 'BLANK_BUSINESS_KEY acct_code'
         WHEN threshold_typed IS NULL                        THEN 'UNCONVERTIBLE sla_threshold'
         WHEN threshold_typed <= 0                           THEN 'RANGE sla_threshold <= 0'
         WHEN sla_type_std='Availability'
              AND threshold_typed > 100                      THEN 'RANGE availability threshold > 100'
         WHEN rate_typed IS NULL                             THEN 'UNCONVERTIBLE penalty_rate_egp'
         WHEN rate_typed < 0                                 THEN 'RANGE penalty_rate_egp < 0'
         WHEN eff_start_typed IS NULL                        THEN 'UNCONVERTIBLE effective_start (NOT NULL)'
         WHEN eff_end_typed IS NOT NULL
              AND eff_end_typed < eff_start_typed            THEN 'CHRONOLOGY effective_end < effective_start'
       END, raw_payload
FROM #sla
WHERE acct_code_std IS NULL OR acct_code_std=''
   OR threshold_typed IS NULL OR threshold_typed <= 0
   OR (sla_type_std='Availability' AND threshold_typed > 100)
   OR rate_typed IS NULL OR rate_typed < 0
   OR eff_start_typed IS NULL
   OR (eff_end_typed IS NOT NULL AND eff_end_typed < eff_start_typed);

TRUNCATE TABLE stg.stg_sla_contract;
INSERT stg.stg_sla_contract (acct_code, sla_type, priority, sla_threshold, penalty_band,
                             penalty_rate_egp, effective_start, effective_end, tier)
SELECT acct_code_std, sla_type_std, priority_std, threshold_typed, penalty_band_std,
       rate_typed, eff_start_typed, eff_end_typed, tier_std
FROM #sla
WHERE acct_code_std IS NOT NULL AND acct_code_std<>''
  AND threshold_typed IS NOT NULL AND threshold_typed > 0
  AND NOT (sla_type_std='Availability' AND threshold_typed > 100)
  AND rate_typed IS NOT NULL AND rate_typed >= 0
  AND eff_start_typed IS NOT NULL
  AND (eff_end_typed IS NULL OR eff_end_typed >= eff_start_typed);
GO


/* =============================================================================
   SECTION 3  -  stg.stg_incident     
   raw.incidents -> stg.stg_incident
   grain: 1 row per incident 
 
   ============================================================================= */
IF OBJECT_ID('stg.stg_incident','U') IS NULL
CREATE TABLE stg.stg_incident (
    inc_id           NVARCHAR(20) NOT NULL,  
    device_id        NVARCHAR(20) NOT NULL,  
    reported_src     NVARCHAR(30) NULL,      
    raised_ts        DATETIME2(0) NOT NULL,  
    ack_ts           DATETIME2(0) NULL,      
    restored_ts      DATETIME2(0) NULL,      
    closed_ts        DATETIME2(0) NULL,      
    priority         NVARCHAR(10) NULL,      
    root_cause_code  NVARCHAR(20) NULL,      
    fault_category   NVARCHAR(30) NULL,      
    vendor           NVARCHAR(30) NULL       
);
GO

IF OBJECT_ID('tempdb..#inc') IS NOT NULL DROP TABLE #inc;
SELECT
    inc_id_std    = UPPER(LTRIM(RTRIM(inc_id))),
    device_id_std = UPPER(LTRIM(RTRIM(device_id))),
    reported_std  = LTRIM(RTRIM(reported_src)),
    raised_typed  = TRY_CONVERT(DATETIME2(0), LTRIM(RTRIM(raised_ts)),   120),
    ack_typed     = TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(ack_ts)),''),     120),
    restored_typed= TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(restored_ts)),''),120),
    closed_typed  = TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(closed_ts)),''),  120),
    priority_std  = UPPER(LTRIM(RTRIM(priority))),
    root_std      = UPPER(LTRIM(RTRIM(root_cause_code))),
    fault_std     = LTRIM(RTRIM(fault_category)),
    vendor_std    = UPPER(LTRIM(RTRIM(vendor))),
    dup_rn        = COUNT(*) OVER (PARTITION BY UPPER(LTRIM(RTRIM(inc_id)))),
    raw_payload   = CONCAT_WS('|', inc_id, device_id, reported_src, raised_ts, ack_ts,
                              restored_ts, closed_ts, priority, root_cause_code, fault_category, vendor)
INTO #inc
FROM raw.incidents;

INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'raw.incidents', inc_id_std,
       CASE
         WHEN inc_id_std IS NULL OR inc_id_std='' THEN 'BLANK_BUSINESS_KEY inc_id'
         WHEN dup_rn > 1                          THEN 'DUPLICATE_BUSINESS_KEY inc_id'
         WHEN device_id_std IS NULL OR device_id_std='' THEN 'BLANK device_id'
         WHEN raised_typed IS NULL                THEN 'UNCONVERTIBLE raised_ts (NOT NULL)'
         WHEN ack_typed IS NOT NULL AND ack_typed < raised_typed           THEN 'CHRONOLOGY ack_ts < raised_ts'
         WHEN restored_typed IS NOT NULL AND restored_typed < raised_typed THEN 'CHRONOLOGY restored_ts < raised_ts'
         WHEN closed_typed IS NOT NULL AND restored_typed IS NOT NULL
              AND closed_typed < restored_typed   THEN 'CHRONOLOGY closed_ts < restored_ts'
       END, raw_payload
FROM #inc
WHERE inc_id_std IS NULL OR inc_id_std=''
   OR dup_rn > 1
   OR device_id_std IS NULL OR device_id_std=''
   OR raised_typed IS NULL
   OR (ack_typed      IS NOT NULL AND ack_typed      < raised_typed)
   OR (restored_typed IS NOT NULL AND restored_typed < raised_typed)
   OR (closed_typed   IS NOT NULL AND restored_typed IS NOT NULL AND closed_typed < restored_typed);

TRUNCATE TABLE stg.stg_incident;
INSERT stg.stg_incident (inc_id, device_id, reported_src, raised_ts, ack_ts, restored_ts,
                         closed_ts, priority, root_cause_code, fault_category, vendor)
SELECT inc_id_std, device_id_std, reported_std, raised_typed, ack_typed, restored_typed,
       closed_typed, priority_std, root_std, fault_std, vendor_std
FROM #inc
WHERE inc_id_std IS NOT NULL AND inc_id_std<>''
  AND dup_rn = 1
  AND device_id_std IS NOT NULL AND device_id_std<>''
  AND raised_typed IS NOT NULL
  AND (ack_typed      IS NULL OR ack_typed      >= raised_typed)
  AND (restored_typed IS NULL OR restored_typed >= raised_typed)
  AND (closed_typed   IS NULL OR restored_typed IS NULL OR closed_typed >= restored_typed);
GO


/* =============================================================================
   SECTION 4  -  stg.stg_service_visit   
   raw.service_visits -> stg.stg_service_visit
   grain: 1 row per engineer visit 
  
   ============================================================================= */
IF OBJECT_ID('stg.stg_service_visit','U') IS NULL
CREATE TABLE stg.stg_service_visit (
    visit_id        NVARCHAR(20)  NOT NULL, 
    inc_id          NVARCHAR(20)  NOT NULL, 
    device_id       NVARCHAR(20)  NOT NULL, 
    visit_seq       INT           NOT NULL, 
    engineer_id     NVARCHAR(20)  NULL,     
    vendor          NVARCHAR(30)  NULL,     
    dispatch_ts     DATETIME2(0)  NOT NULL, 
    arrival_ts      DATETIME2(0)  NULL,     
    completion_ts   DATETIME2(0)  NULL,     
    visit_type      NVARCHAR(30)  NULL,     
    visit_outcome   NVARCHAR(30)  NULL,     
    parts_replaced  NVARCHAR(200) NULL      
);
GO

IF OBJECT_ID('tempdb..#vis') IS NOT NULL DROP TABLE #vis;
SELECT
    visit_id_std  = UPPER(LTRIM(RTRIM(visit_id))),
    inc_id_std    = UPPER(LTRIM(RTRIM(inc_id))),
    device_id_std = UPPER(LTRIM(RTRIM(device_id))),
    visit_seq_typed = TRY_CONVERT(INT, LTRIM(RTRIM(visit_seq))),
    engineer_std  = UPPER(LTRIM(RTRIM(engineer_id))),
    vendor_std    = UPPER(LTRIM(RTRIM(vendor))),
    dispatch_typed= TRY_CONVERT(DATETIME2(0), LTRIM(RTRIM(dispatch_ts)),   120),
    arrival_typed = TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(arrival_ts)),''),   120),
    completion_typed = TRY_CONVERT(DATETIME2(0), NULLIF(LTRIM(RTRIM(completion_ts)),''),120),
    visit_type_std= LTRIM(RTRIM(visit_type)),
    outcome_std   = LTRIM(RTRIM(visit_outcome)),
    parts_std     = NULLIF(LTRIM(RTRIM(parts_replaced)),''),
    dup_rn        = COUNT(*) OVER (PARTITION BY UPPER(LTRIM(RTRIM(visit_id)))),
    raw_payload   = CONCAT_WS('|', visit_id, inc_id, device_id, visit_seq, engineer_id, vendor,
                              dispatch_ts, arrival_ts, completion_ts, visit_type, visit_outcome, parts_replaced)
INTO #vis
FROM raw.service_visits;

INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'raw.service_visits', visit_id_std,
       CASE
         WHEN visit_id_std IS NULL OR visit_id_std='' THEN 'BLANK_BUSINESS_KEY visit_id'
         WHEN dup_rn > 1                              THEN 'DUPLICATE_BUSINESS_KEY visit_id'
         WHEN inc_id_std IS NULL OR inc_id_std=''     THEN 'BLANK inc_id'
         WHEN device_id_std IS NULL OR device_id_std='' THEN 'BLANK device_id'
         WHEN visit_seq_typed IS NULL                 THEN 'UNCONVERTIBLE visit_seq'
         WHEN visit_seq_typed < 1                     THEN 'RANGE visit_seq < 1'
         WHEN dispatch_typed IS NULL                  THEN 'UNCONVERTIBLE dispatch_ts (NOT NULL)'
         WHEN arrival_typed IS NOT NULL AND arrival_typed < dispatch_typed THEN 'CHRONOLOGY arrival_ts < dispatch_ts'
         WHEN completion_typed IS NOT NULL AND arrival_typed IS NOT NULL
              AND completion_typed < arrival_typed    THEN 'CHRONOLOGY completion_ts < arrival_ts'
       END, raw_payload
FROM #vis
WHERE visit_id_std IS NULL OR visit_id_std=''
   OR dup_rn > 1
   OR inc_id_std IS NULL OR inc_id_std=''
   OR device_id_std IS NULL OR device_id_std=''
   OR visit_seq_typed IS NULL OR visit_seq_typed < 1
   OR dispatch_typed IS NULL
   OR (arrival_typed IS NOT NULL AND arrival_typed < dispatch_typed)
   OR (completion_typed IS NOT NULL AND arrival_typed IS NOT NULL AND completion_typed < arrival_typed);

TRUNCATE TABLE stg.stg_service_visit;
INSERT stg.stg_service_visit (visit_id, inc_id, device_id, visit_seq, engineer_id, vendor,
                              dispatch_ts, arrival_ts, completion_ts, visit_type, visit_outcome, parts_replaced)
SELECT visit_id_std, inc_id_std, device_id_std, visit_seq_typed, engineer_std, vendor_std,
       dispatch_typed, arrival_typed, completion_typed, visit_type_std, outcome_std, parts_std
FROM #vis
WHERE visit_id_std IS NOT NULL AND visit_id_std<>''
  AND dup_rn = 1
  AND inc_id_std IS NOT NULL AND inc_id_std<>''
  AND device_id_std IS NOT NULL AND device_id_std<>''
  AND visit_seq_typed IS NOT NULL AND visit_seq_typed >= 1
  AND dispatch_typed IS NOT NULL
  AND (arrival_typed IS NULL OR arrival_typed >= dispatch_typed)
  AND (completion_typed IS NULL OR arrival_typed IS NULL OR completion_typed >= arrival_typed);
GO


/* =============================================================================
   SECTION 5  -  stg.stg_telemetry_event     
   raw.telemetry_events -> stg.stg_telemetry_event
   grain: 1 row per device event
 
  
   ============================================================================= */
IF OBJECT_ID('stg.stg_telemetry_event','U') IS NULL
CREATE TABLE stg.stg_telemetry_event (
    evt_id        NVARCHAR(30) NOT NULL,  
    device_id     NVARCHAR(20) NOT NULL,  
    evt_ts        DATETIME2(0) NOT NULL,  
    state         NVARCHAR(20) NULL,      
    evt_code      NVARCHAR(20) NULL,      
    src           NVARCHAR(20) NULL,      
    source_month  CHAR(6)      NOT NULL   
);
GO

-- High-volume fact: stage the typed/dedup logic once into a temp table, then split.
IF OBJECT_ID('tempdb..#tel') IS NOT NULL DROP TABLE #tel;
SELECT
    evt_id_std    = LTRIM(RTRIM(evt_id)),
    device_id_std = UPPER(LTRIM(RTRIM(device_id))),
    evt_ts_typed  = TRY_CONVERT(DATETIME2(0), LTRIM(RTRIM(evt_ts)), 120),
    state_std     = UPPER(LTRIM(RTRIM(state))),
    evt_code_std  = NULLIF(UPPER(LTRIM(RTRIM(evt_code))),''),
    src_std       = UPPER(LTRIM(RTRIM(src))),
    dup_rn        = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(evt_id))
                                       ORDER BY (SELECT NULL)),
    raw_payload   = CONCAT_WS('|', evt_id, device_id, evt_ts, state, evt_code, src)
INTO #tel
FROM raw.telemetry_events;

INSERT stg.dq_reject (source_table, business_key, reject_rule, raw_payload)
SELECT 'raw.telemetry_events', evt_id_std,
       CASE
         WHEN evt_id_std IS NULL OR evt_id_std='' THEN 'BLANK_BUSINESS_KEY evt_id'
         WHEN dup_rn > 1                          THEN 'DUPLICATE_BUSINESS_KEY evt_id'
         WHEN device_id_std IS NULL OR device_id_std='' THEN 'BLANK device_id'
         WHEN evt_ts_typed IS NULL                THEN 'UNCONVERTIBLE evt_ts (NOT NULL)'
       END, raw_payload
FROM #tel
WHERE evt_id_std IS NULL OR evt_id_std=''
   OR dup_rn > 1
   OR device_id_std IS NULL OR device_id_std=''
   OR evt_ts_typed IS NULL;

TRUNCATE TABLE stg.stg_telemetry_event;
INSERT stg.stg_telemetry_event (evt_id, device_id, evt_ts, state, evt_code, src, source_month)
SELECT evt_id_std, device_id_std, evt_ts_typed, state_std, evt_code_std, src_std,
       CONVERT(CHAR(6), evt_ts_typed, 112)        
FROM #tel
WHERE evt_id_std IS NOT NULL AND evt_id_std<>''
  AND dup_rn = 1
  AND device_id_std IS NOT NULL AND device_id_std<>''
  AND evt_ts_typed IS NOT NULL;
GO


/* =============================================================================
   SECTION 6  -  DATA-QUALITY VALIDATION REPORTS (domain/enum conformance)

   ============================================================================= */

-- 6.1 device domain conformance
SELECT 'device.acct_code'  AS check_name, acct_code AS bad_value, COUNT(*) AS n
FROM stg.stg_device WHERE acct_code NOT IN ('AAIB','BDC','CIB','FAISAL','MISR','NBE','QNB') GROUP BY acct_code
UNION ALL SELECT 'device.region(unmapped)', '(NULL after canonicalise)', COUNT(*) FROM stg.stg_device WHERE region IS NULL
UNION ALL SELECT 'device.deployment_type', deployment_type, COUNT(*) FROM stg.stg_device WHERE deployment_type NOT IN ('Branch','Drive-Through','Lobby','Offsite') GROUP BY deployment_type
UNION ALL SELECT 'device.status', status, COUNT(*) FROM stg.stg_device WHERE status NOT IN ('Active','Inactive') GROUP BY status
UNION ALL SELECT 'device.sla_tier', sla_tier, COUNT(*) FROM stg.stg_device WHERE sla_tier NOT IN ('Gold','Silver') GROUP BY sla_tier;

-- 6.2 sla domain conformance
SELECT 'sla.sla_type' AS check_name, sla_type AS bad_value, COUNT(*) AS n
FROM stg.stg_sla_contract WHERE sla_type NOT IN ('Availability','Response','Restoration') GROUP BY sla_type
UNION ALL SELECT 'sla.priority', priority, COUNT(*) FROM stg.stg_sla_contract WHERE priority NOT IN ('ALL','P1','P2','P3','P4') GROUP BY priority
UNION ALL SELECT 'sla.tier', tier, COUNT(*) FROM stg.stg_sla_contract WHERE tier NOT IN ('ALL','Gold','Silver') GROUP BY tier;

-- 6.3 incident domain conformance
SELECT 'incident.priority' AS check_name, priority AS bad_value, COUNT(*) AS n
FROM stg.stg_incident WHERE priority NOT IN ('P1','P2','P3','P4') GROUP BY priority
UNION ALL SELECT 'incident.reported_src', reported_src, COUNT(*) FROM stg.stg_incident
  WHERE reported_src NOT IN ('Branch Staff','Call Center','Customer Complaint','Monitoring System') GROUP BY reported_src
UNION ALL SELECT 'incident.vendor', vendor, COUNT(*) FROM stg.stg_incident
  WHERE vendor NOT IN ('VENDOR_A','VENDOR_B','VENDOR_C','VENDOR_D') GROUP BY vendor;

-- 6.4 visit domain conformance
SELECT 'visit.visit_type' AS check_name, visit_type AS bad_value, COUNT(*) AS n
FROM stg.stg_service_visit WHERE visit_type NOT IN ('Corrective','Preventive') GROUP BY visit_type
UNION ALL SELECT 'visit.visit_outcome', visit_outcome, COUNT(*) FROM stg.stg_service_visit
  WHERE visit_outcome NOT IN ('Fixed','Further Visit','No Fault Found','Not Fixed','Parts Required') GROUP BY visit_outcome
UNION ALL SELECT 'visit.vendor', vendor, COUNT(*) FROM stg.stg_service_visit
  WHERE vendor NOT IN ('VENDOR_A','VENDOR_B','VENDOR_C','VENDOR_D') GROUP BY vendor;

-- 6.5 telemetry domain conformance (evt_code NULL is EXPECTED, not a violation)
SELECT 'telemetry.state' AS check_name, state AS bad_value, COUNT(*) AS n
FROM stg.stg_telemetry_event
WHERE state NOT IN ('COMMS_LOST','IN_SERVICE','OFFLINE','OUT_OF_SERVICE','SUPERVISOR') GROUP BY state
UNION ALL SELECT 'telemetry.src', src, COUNT(*) FROM stg.stg_telemetry_event
  WHERE src NOT IN ('NOC-PRIMARY','NOC-SECONDARY') GROUP BY src;
GO

/* =============================================================================
   SECTION 7  -  LOAD RECONCILIATION  (raw -> stg + rejects must balance)
   ============================================================================= */
SELECT 'stg_device'          AS stg_table, (SELECT COUNT(*) FROM raw.atm_device_master)      AS raw_rows,
       (SELECT COUNT(*) FROM stg.stg_device) AS stg_rows,
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='raw.atm_device_master') AS rejected
UNION ALL SELECT 'stg_sla_contract', (SELECT COUNT(*) FROM raw.sla_contract_reference),
       (SELECT COUNT(*) FROM stg.stg_sla_contract),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='raw.sla_contract_reference')
UNION ALL SELECT 'stg_incident', (SELECT COUNT(*) FROM raw.incidents),
       (SELECT COUNT(*) FROM stg.stg_incident),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='raw.incidents')
UNION ALL SELECT 'stg_service_visit', (SELECT COUNT(*) FROM raw.service_visits),
       (SELECT COUNT(*) FROM stg.stg_service_visit),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='raw.service_visits')
UNION ALL SELECT 'stg_telemetry_event', (SELECT COUNT(*) FROM raw.telemetry_events),
       (SELECT COUNT(*) FROM stg.stg_telemetry_event),
       (SELECT COUNT(*) FROM stg.dq_reject WHERE source_table='raw.telemetry_events');
GO
/* End of staging layer script.  Invariant: raw_rows = stg_rows + rejected. */


SELECT TOP 20
       business_key,
       COUNT(*) AS rejected_rows
FROM stg.dq_reject
WHERE reject_rule = 'DUPLICATE_BUSINESS_KEY evt_id'
GROUP BY business_key
ORDER BY rejected_rows DESC;





SELECT
    COUNT(DISTINCT business_key) AS duplicate_event_ids
FROM stg.dq_reject
WHERE reject_rule = 'DUPLICATE_BUSINESS_KEY evt_id';





SELECT TOP 20 *
FROM stg.dq_reject
WHERE reject_rule = 'DUPLICATE_BUSINESS_KEY evt_id';


SELECT TOP 20
       business_key,
       raw_payload
FROM stg.dq_reject;
