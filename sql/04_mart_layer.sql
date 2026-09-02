/* =============================================================================
   ATM Operations Analytics  -  MART LAYER PHYSICAL IMPLEMENTATION
 
   Database:    ATMOpsAnalytics
   Schema:      mart
  
   Architecture: raw -> stg -> core -> mart   
        ============================================================================= */

USE ATMOpsAnalytics;
GO

IF SCHEMA_ID('mart') IS NULL EXEC('CREATE SCHEMA mart;');
GO

IF OBJECT_ID('mart.etl_control','U') IS NULL
CREATE TABLE mart.etl_control (
    k             NVARCHAR(40)  NOT NULL PRIMARY KEY,
    v_date        DATE          NULL,
    v_datetime    DATETIME2(0)  NULL,
    set_ts        DATETIME2(0)  NOT NULL
);
GO

DELETE FROM mart.etl_control;

DECLARE @max_evt DATETIME2(0);
SELECT @max_evt = MAX(evt_ts) FROM core.fact_telemetry_event;

DECLARE @reporting_anchor DATE = CONVERT(DATE, @max_evt);

DECLARE @window_end DATETIME2(0) =
        CAST(DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@max_evt), MONTH(@max_evt), 1)) AS DATETIME2(0));

INSERT mart.etl_control (k, v_date, v_datetime, set_ts) VALUES
   ('reporting_anchor', @reporting_anchor, NULL,         SYSUTCDATETIME()),
   ('window_end',       NULL,              @window_end,  SYSUTCDATETIME());
GO




CREATE OR ALTER VIEW mart.vw_dim_device AS
SELECT
    device_key,
    device_id,
    acct_code,
    acct_name,
    region,
    deployment_type,
    model,
    install_dt,
    decommission_dt,
    status,
    sla_tier,
    is_active
FROM core.dim_device;
GO

CREATE OR ALTER VIEW mart.vw_dim_date AS
SELECT
    date_key,
    full_date,
    [year],
    [quarter],
    [month],
    month_name,
    [day],
    day_of_week,
    is_weekend,
    ([year] * 100 + [month]) AS month_key        
FROM core.dim_date;
GO

CREATE OR ALTER VIEW mart.vw_dim_sla_contract AS
SELECT
    sla_contract_key,
    acct_code,
    sla_type,
    priority,
    sla_threshold,
    penalty_band,
    penalty_rate_egp,
    effective_start,
    effective_end,
    tier,
    is_current
FROM core.dim_sla_contract;
GO


/* =============================================================================
     mart.fact_availability_device_month   
  
   ============================================================================= */

IF OBJECT_ID('mart.fact_availability_device_month','U') IS NULL
CREATE TABLE mart.fact_availability_device_month (
    device_key            INT          NOT NULL,
    month_key             INT          NOT NULL,       
    acct_code             NVARCHAR(10) NOT NULL,       
    sla_tier              NVARCHAR(20) NOT NULL,
    in_scope_up_minutes   BIGINT       NOT NULL,       
    in_scope_down_minutes BIGINT       NOT NULL,       
    in_scope_total_minutes BIGINT      NOT NULL,       
    out_of_scope_minutes  BIGINT       NOT NULL,       
    availability_pct      DECIMAL(7,4) NULL,           
    load_ts               DATETIME2(0) NOT NULL,
    CONSTRAINT PK_fact_avail_dm PRIMARY KEY (device_key, month_key),
    CONSTRAINT FK_avail_device FOREIGN KEY (device_key) REFERENCES core.dim_device(device_key)
);
GO

TRUNCATE TABLE mart.fact_availability_device_month;
GO

DECLARE @window_end DATETIME2(0) = (SELECT v_datetime FROM mart.etl_control WHERE k='window_end');

;WITH

in_scope_inc AS (
    SELECT device_key, raised_ts, restored_ts
    FROM core.fact_incident
    WHERE restored_ts IS NOT NULL
      AND root_cause_code IN ('HW-CRD','HW-DISP','HW-JRNL','HW-PRN','SW-APP','SW-OS')
),

intervals AS (
    SELECT
        t.device_key,
        t.state,
        t.evt_ts AS interval_start,
        LEAD(t.evt_ts) OVER (PARTITION BY t.device_key ORDER BY t.evt_ts, t.telemetry_key)
            AS next_ts
    FROM core.fact_telemetry_event t
),

bounded AS (
    SELECT
        i.device_key,
        i.state,
        i.interval_start,
        (SELECT MIN(x) FROM (VALUES
              (COALESCE(i.next_ts, @window_end)),
              (@window_end),
              (COALESCE(CAST(d.decommission_dt AS DATETIME2(0)), @window_end))
         ) v(x)) 
         AS interval_end
    FROM intervals i
    INNER JOIN core.dim_device d ON d.device_key = i.device_key
),
flagged AS (
    SELECT
        b.device_key, b.state, b.interval_start, b.interval_end,
        CASE
            WHEN b.state = 'IN_SERVICE' THEN 'UP'
            WHEN b.state IN ('OUT_OF_SERVICE','OFFLINE','SUPERVISOR')
                 AND EXISTS (SELECT 1 FROM in_scope_inc s
                             WHERE s.device_key = b.device_key
                               AND s.raised_ts   < b.interval_end
                               AND s.restored_ts > b.interval_start)
                 THEN 'DOWN_INSCOPE'
            ELSE 'OOS'                                      
        END AS scope_class
    FROM bounded b
    WHERE b.interval_end > b.interval_start               
),

month_spine AS (
    SELECT DISTINCT
        ([year]*100 + [month])                                       AS month_key,
        CAST(DATEFROMPARTS([year],[month],1) AS DATETIME2(0))        AS m_start,
        CAST(DATEADD(MONTH,1,DATEFROMPARTS([year],[month],1)) AS DATETIME2(0)) AS m_next
    FROM core.dim_date
),

split AS (
    SELECT
        f.device_key,
        ms.month_key,
        f.scope_class,
        DATEDIFF(MINUTE,
                 CASE WHEN f.interval_start > ms.m_start THEN f.interval_start ELSE ms.m_start END,
                 CASE WHEN f.interval_end   < ms.m_next  THEN f.interval_end   ELSE ms.m_next  END
        ) AS minutes
    FROM flagged f
    INNER JOIN month_spine ms
        ON f.interval_start < ms.m_next
       AND f.interval_end   > ms.m_start
)
INSERT mart.fact_availability_device_month
    (device_key, month_key, acct_code, sla_tier,
     in_scope_up_minutes, in_scope_down_minutes, in_scope_total_minutes,
     out_of_scope_minutes, availability_pct, load_ts)
SELECT
    s.device_key,
    s.month_key,
    d.acct_code,
    d.sla_tier,
    SUM(CASE WHEN s.scope_class = 'UP'           THEN s.minutes ELSE 0 END)                       AS in_scope_up_minutes,
    SUM(CASE WHEN s.scope_class = 'DOWN_INSCOPE' THEN s.minutes ELSE 0 END)                       AS in_scope_down_minutes,
    SUM(CASE WHEN s.scope_class IN ('UP','DOWN_INSCOPE') THEN s.minutes ELSE 0 END)               AS in_scope_total_minutes,
    SUM(CASE WHEN s.scope_class = 'OOS'          THEN s.minutes ELSE 0 END)                       AS out_of_scope_minutes,
    CASE WHEN SUM(CASE WHEN s.scope_class IN ('UP','DOWN_INSCOPE') THEN s.minutes ELSE 0 END) > 0
         THEN CONVERT(DECIMAL(7,4),
                100.0 * SUM(CASE WHEN s.scope_class = 'UP' THEN s.minutes ELSE 0 END)
                      / SUM(CASE WHEN s.scope_class IN ('UP','DOWN_INSCOPE') THEN s.minutes ELSE 0 END))
         ELSE NULL END                                                                            AS availability_pct,
    SYSUTCDATETIME()
FROM split s
INNER JOIN core.dim_device d ON d.device_key = s.device_key
WHERE s.minutes > 0
GROUP BY s.device_key, s.month_key, d.acct_code, d.sla_tier;
GO


/* =============================================================================
    mart.fact_sla_penalty_account_tier_month  
     ============================================================================= */

IF OBJECT_ID('mart.fact_sla_penalty_account_tier_month','U') IS NULL
CREATE TABLE mart.fact_sla_penalty_account_tier_month (
    acct_code               NVARCHAR(10) NOT NULL,
    sla_tier                NVARCHAR(20) NOT NULL,
    month_key               INT          NOT NULL,    
    in_scope_up_minutes     BIGINT       NOT NULL,
    in_scope_total_minutes  BIGINT       NOT NULL,
    availability_pct        DECIMAL(7,4) NULL,
    device_count            INT          NOT NULL,        

    compliance_threshold_pct DECIMAL(6,2) NULL,          
    is_sla_compliant        BIT          NULL,           
   
    availability_penalty_egp INT         NOT NULL,       
    availability_penalty_band NVARCHAR(20) NULL,         
    response_breach_count   INT          NOT NULL,       
    response_penalty_egp    INT          NOT NULL,
    restoration_breach_count INT         NOT NULL,       
    restoration_penalty_egp INT          NOT NULL,
  
    penalty_accrued_egp     INT          NOT NULL,       
    penalty_realised_egp    INT          NOT NULL,       
    is_month_closed         BIT          NOT NULL,
    load_ts                 DATETIME2(0) NOT NULL,
    CONSTRAINT PK_fact_pen_atm PRIMARY KEY (acct_code, sla_tier, month_key)
);
GO

TRUNCATE TABLE mart.fact_sla_penalty_account_tier_month;
GO

DECLARE @anchor DATE = (SELECT v_date FROM mart.etl_control WHERE k='reporting_anchor');

;WITH

avail_rollup AS (
    SELECT
        acct_code, sla_tier, month_key,
        SUM(in_scope_up_minutes)    AS up_min,
        SUM(in_scope_total_minutes) AS tot_min,
        COUNT(*)                    AS device_count
    FROM mart.fact_availability_device_month
    GROUP BY acct_code, sla_tier, month_key
),
avail AS (
    SELECT
        r.*,
        CASE WHEN r.tot_min > 0
             THEN CONVERT(DECIMAL(7,4), 100.0 * r.up_min / r.tot_min)
             ELSE NULL END AS availability_pct,
        DATEFROMPARTS(r.month_key/100, r.month_key%100, 1) AS m_first
    FROM avail_rollup r
),

inc AS (
    SELECT
        d.acct_code, d.sla_tier,
        (YEAR(i.raised_ts)*100 + MONTH(i.raised_ts)) AS month_key,
        i.priority, i.ack_minutes, i.ttr_minutes, i.raised_ts
    FROM core.fact_incident i
    INNER JOIN core.dim_device d ON d.device_key = i.device_key
    WHERE i.root_cause_code IN ('HW-CRD','HW-DISP','HW-JRNL','HW-PRN','SW-APP','SW-OS')
),

resp AS (
    SELECT
        x.acct_code, x.sla_tier, x.month_key,
        COUNT(*)                              AS breach_count,
        SUM(c.penalty_rate_egp)               AS penalty_egp
    FROM inc x
    INNER JOIN core.dim_sla_contract c
        ON c.acct_code = x.acct_code
       AND c.sla_type  = 'Response'
       AND c.priority  = x.priority
       AND c.tier      = 'ALL'
       AND x.raised_ts >= c.effective_start
       AND (c.effective_end IS NULL OR x.raised_ts <= DATEADD(DAY,1,c.effective_end))
    WHERE x.ack_minutes IS NOT NULL
      AND x.ack_minutes > c.sla_threshold * 60.0
    GROUP BY x.acct_code, x.sla_tier, x.month_key
),

rest AS (
    SELECT
        x.acct_code, x.sla_tier, x.month_key,
        COUNT(*)                              AS breach_count,
        SUM(c.penalty_rate_egp)               AS penalty_egp
    FROM inc x
    INNER JOIN core.dim_sla_contract c
        ON c.acct_code = x.acct_code
       AND c.sla_type  = 'Restoration'
       AND c.priority  = x.priority
       AND c.tier      = 'ALL'
       AND x.raised_ts >= c.effective_start
       AND (c.effective_end IS NULL OR x.raised_ts <= DATEADD(DAY,1,c.effective_end))
    WHERE x.ttr_minutes IS NOT NULL
      AND x.ttr_minutes > c.sla_threshold * 60.0
    GROUP BY x.acct_code, x.sla_tier, x.month_key
)
INSERT mart.fact_sla_penalty_account_tier_month
    (acct_code, sla_tier, month_key,
     in_scope_up_minutes, in_scope_total_minutes, availability_pct, device_count,
     compliance_threshold_pct, is_sla_compliant,
     availability_penalty_egp, availability_penalty_band,
     response_breach_count, response_penalty_egp,
     restoration_breach_count, restoration_penalty_egp,
     penalty_accrued_egp, penalty_realised_egp, is_month_closed, load_ts)
SELECT
    a.acct_code, a.sla_tier, a.month_key,
    a.up_min, a.tot_min, a.availability_pct, a.device_count,
   
    thr.compliance_threshold_pct,
    CASE WHEN a.availability_pct IS NULL OR thr.compliance_threshold_pct IS NULL THEN NULL
         WHEN a.availability_pct >= thr.compliance_threshold_pct THEN 1 ELSE 0 END AS is_sla_compliant,
  
    COALESCE(band.worst_rate, 0)                                                   AS availability_penalty_egp,
    band.worst_band                                                               AS availability_penalty_band,
    COALESCE(resp.breach_count, 0)                                                AS response_breach_count,
    COALESCE(resp.penalty_egp, 0)                                                 AS response_penalty_egp,
    COALESCE(rest.breach_count, 0)                                                AS restoration_breach_count,
    COALESCE(rest.penalty_egp, 0)                                                 AS restoration_penalty_egp,
    
    (COALESCE(band.worst_rate,0) + COALESCE(resp.penalty_egp,0) + COALESCE(rest.penalty_egp,0))
                                                                                  AS penalty_accrued_egp,
    
    CASE WHEN EOMONTH(a.m_first) < @anchor
         THEN (COALESCE(band.worst_rate,0) + COALESCE(resp.penalty_egp,0) + COALESCE(rest.penalty_egp,0))
         ELSE 0 END                                                               AS penalty_realised_egp,
    CASE WHEN EOMONTH(a.m_first) < @anchor THEN 1 ELSE 0 END                      AS is_month_closed,
    SYSUTCDATETIME()
FROM avail a

OUTER APPLY (
    SELECT MAX(c.sla_threshold) AS compliance_threshold_pct
    FROM core.dim_sla_contract c
    WHERE c.acct_code = a.acct_code AND c.tier = a.sla_tier
      AND c.sla_type = 'Availability' AND c.priority = 'ALL'
      AND a.m_first >= c.effective_start
      AND (c.effective_end IS NULL OR a.m_first <= c.effective_end)
) thr

OUTER APPLY (
    SELECT TOP (1) c.penalty_rate_egp AS worst_rate, c.penalty_band AS worst_band
    FROM core.dim_sla_contract c
    WHERE c.acct_code = a.acct_code AND c.tier = a.sla_tier
      AND c.sla_type = 'Availability' AND c.priority = 'ALL'
      AND a.m_first >= c.effective_start
      AND (c.effective_end IS NULL OR a.m_first <= c.effective_end)
      AND a.availability_pct IS NOT NULL
      AND a.availability_pct < c.sla_threshold
    ORDER BY c.penalty_rate_egp DESC
) band
LEFT JOIN resp ON resp.acct_code=a.acct_code AND resp.sla_tier=a.sla_tier AND resp.month_key=a.month_key
LEFT JOIN rest ON rest.acct_code=a.acct_code AND rest.sla_tier=a.sla_tier AND rest.month_key=a.month_key;
GO


/* =============================================================================
  mart.vw_incident_restoration 
 
   ============================================================================= */

CREATE OR ALTER VIEW mart.vw_incident_restoration AS
SELECT
    i.inc_id,
    i.device_key,
    d.device_id,
    d.acct_code,
    d.acct_name,
    d.sla_tier,
    d.region,
    i.vendor,
    i.priority,
    i.root_cause_code,
    i.fault_category,
    i.raised_ts,
    i.restored_ts,
    (YEAR(i.raised_ts)*100 + MONTH(i.raised_ts))         AS month_key,
    i.ttr_minutes,                                  
    c.sla_threshold                                      AS restoration_threshold_hours,
    CASE WHEN i.ttr_minutes > c.sla_threshold * 60.0 THEN 1 ELSE 0 END
                                                         AS is_restoration_breach
FROM core.fact_incident i
INNER JOIN core.dim_device d ON d.device_key = i.device_key
LEFT JOIN core.dim_sla_contract c
       ON c.acct_code = d.acct_code
      AND c.sla_type  = 'Restoration'
      AND c.priority  = i.priority
      AND c.tier      = 'ALL'
      AND i.raised_ts >= c.effective_start
      AND (c.effective_end IS NULL OR i.raised_ts <= DATEADD(DAY,1,c.effective_end))
WHERE i.restored_ts IS NOT NULL
  AND i.root_cause_code IN ('HW-CRD','HW-DISP','HW-JRNL','HW-PRN','SW-APP','SW-OS');   -- A3
GO


/* =============================================================================
    mart.vw_incident_field_quality  
  
   ============================================================================= */

CREATE OR ALTER VIEW mart.vw_incident_field_quality AS
WITH v AS (
    SELECT
        inc_id,
        COUNT(*)                                                        AS visit_count,
        MAX(CASE WHEN visit_seq = 1 THEN visit_outcome END)            AS first_visit_outcome,
        MAX(CASE WHEN visit_seq = 1 THEN vendor END)                   AS first_visit_vendor
    FROM core.fact_service_visit
    GROUP BY inc_id
)
SELECT
    i.inc_id,
    i.device_key,
    d.device_id,
    d.acct_code,
    d.acct_name,
    d.sla_tier,
    d.region,
    i.vendor,                                            
    v.first_visit_vendor,                                
    i.priority,
    i.root_cause_code,
    (YEAR(i.raised_ts)*100 + MONTH(i.raised_ts))         AS month_key,
    v.visit_count,
    v.first_visit_outcome,
    CASE WHEN v.visit_count = 1 AND v.first_visit_outcome = 'Fixed' THEN 1 ELSE 0 END
                                                         AS is_first_time_fix,  
    CASE WHEN v.visit_count > 1 THEN 1 ELSE 0 END        AS is_repeat_visit     
FROM core.fact_incident i
INNER JOIN core.dim_device d ON d.device_key = i.device_key
INNER JOIN v               ON v.inc_id = i.inc_id       
WHERE i.root_cause_code IN ('HW-CRD','HW-DISP','HW-JRNL','HW-PRN','SW-APP','SW-OS');  
GO


/* =============================================================================
    VALIDATION, RECONCILIATION & KPI CONTROL QUERIES

   ============================================================================= */

--  ROW-COUNT validation -------------------------------------------------

SELECT 'fact_availability_device_month' AS object_name,
       COUNT(*)                          AS row_count,
       COUNT(DISTINCT device_key)        AS distinct_devices,
       COUNT(DISTINCT month_key)         AS distinct_months
FROM mart.fact_availability_device_month;
    
SELECT 'fact_sla_penalty_account_tier_month' AS object_name,
       COUNT(*)                                AS row_count,       
       COUNT(DISTINCT acct_code)               AS accounts,        
       COUNT(DISTINCT sla_tier)                AS tiers,           
       COUNT(DISTINCT month_key)               AS months           
FROM mart.fact_sla_penalty_account_tier_month;

--------------- GRAIN uniqueness sentinels  --------------------------------
SELECT 'avail_dm grain' AS grain_check,
       COUNT(*) - COUNT(DISTINCT CONCAT(device_key,'|',month_key)) AS dup_count
FROM mart.fact_availability_device_month
UNION ALL
SELECT 'penalty_atm grain',
       COUNT(*) - COUNT(DISTINCT CONCAT(acct_code,'|',sla_tier,'|',month_key))
FROM mart.fact_sla_penalty_account_tier_month;


SELECT 'avail minutes identity' AS control,
       SUM(CASE WHEN in_scope_up_minutes + in_scope_down_minutes
                     <> in_scope_total_minutes THEN 1 ELSE 0 END) AS violations
FROM mart.fact_availability_device_month;

--  MINUTE RECONCILIATION between grains  -----------------------

SELECT 'device->account_tier minute reconciliation' AS control,
       SUM(ABS(d.up_min - p.in_scope_up_minutes))   AS up_diff,
       SUM(ABS(d.tot_min - p.in_scope_total_minutes)) AS total_diff 
FROM (
    SELECT acct_code, sla_tier, month_key,
           SUM(in_scope_up_minutes) up_min, SUM(in_scope_total_minutes) tot_min
    FROM mart.fact_availability_device_month
    GROUP BY acct_code, sla_tier, month_key
) d
INNER JOIN mart.fact_sla_penalty_account_tier_month p
    ON p.acct_code=d.acct_code AND p.sla_tier=d.sla_tier AND p.month_key=d.month_key;


SELECT TOP 10
       p.acct_code, p.sla_tier, p.month_key,
       p.availability_pct                       AS minute_weighted_pct,   
       CONVERT(DECIMAL(7,4), AVG(dm.availability_pct)) AS naive_avg_pct,  
       CONVERT(DECIMAL(7,4),
               p.availability_pct - AVG(dm.availability_pct)) AS difference
FROM mart.fact_sla_penalty_account_tier_month p
INNER JOIN mart.fact_availability_device_month dm
    ON dm.acct_code=p.acct_code AND dm.sla_tier=p.sla_tier AND dm.month_key=p.month_key
WHERE dm.availability_pct IS NOT NULL
GROUP BY p.acct_code, p.sla_tier, p.month_key, p.availability_pct
ORDER BY ABS(p.availability_pct - AVG(dm.availability_pct)) DESC;


SELECT 'penalty band consistency' AS control,
       SUM(CASE WHEN p.availability_penalty_egp > 0 AND chk.expected_rate IS NULL
                THEN 1
                WHEN p.availability_penalty_egp <> COALESCE(chk.expected_rate,0)
                THEN 1 ELSE 0 END) AS violations
FROM mart.fact_sla_penalty_account_tier_month p
OUTER APPLY (
    SELECT MAX(c.penalty_rate_egp) AS expected_rate
    FROM core.dim_sla_contract c
    WHERE c.acct_code=p.acct_code AND c.tier=p.sla_tier
      AND c.sla_type='Availability' AND c.priority='ALL'
      AND p.availability_pct IS NOT NULL
      AND p.availability_pct < c.sla_threshold
) chk;


SELECT 'out_of_scope incidents excluded from penalty' AS control,
       COUNT(*) AS excluded_incidents
FROM core.fact_incident
WHERE root_cause_code NOT IN ('HW-CRD','HW-DISP','HW-JRNL','HW-PRN','SW-APP','SW-OS');
--
