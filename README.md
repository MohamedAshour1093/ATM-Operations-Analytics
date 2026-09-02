# ATM Operations Analytics

End-to-end SLA, availability, and penalty-exposure analytics for a managed-services ATM operations provider, built on a governed SQL Server warehouse and a Power BI reporting layer.

## Business Context

The provider operates and maintains bank-owned ATM fleets under commercial SLAs with financial penalties for missed contractual thresholds.

Operational data comes from device monitoring, incident ticketing, and field dispatch systems, creating reconciliation challenges that can affect the reliability of monthly SLA and penalty reporting.

This project delivers an analytical solution to monitor contracted availability, SLA and penalty exposure, restoration performance, field-service quality, and vendor performance.

## Business Objectives

- **Monitor ATM availability** and identify performance gaps across accounts and time.
- **Measure contractual SLA compliance** across accounts, SLA tiers, and reporting months.
- **Quantify penalty exposure** and identify the main financial drivers.
- **Assess restoration performance** using Median and P90 MTTR.
- **Evaluate field-service quality** through FTFR and Repeat Visit Rate.
- **Identify operational areas requiring targeted improvement** across vendors, regions, and SLA segments.

## Executive Snapshot

| KPI | Result |
|---|---:|
| Technical Availability | **98.37%** |
| SLA Compliance | **90.77%** |
| Penalty Accrued | **2.48M EGP** |
| Penalty Realised | **2.36M EGP** |
| Median MTTR | **379 min** |
| P90 MTTR | **1,299 min** |
| First-Time Fix Rate (FTFR) | **79.44%** |
| Repeat Visit Rate | **20.56%** |

## Solution Architecture

The solution follows a layered SQL Server warehouse architecture that separates source ingestion, data-quality processing, business integration, and analytical consumption.

### Data Flow

`Source Data → RAW → STG → CORE → MART → Power BI`

| Layer | Role |
|---|---|
| RAW | Source-faithful ingestion and traceability |
| STG | Typed, standardised, and validated data |
| CORE | Integrated dimensions and operational facts; KPI calculation source of truth |
| MART | Reporting-ready analytical outputs |
| Power BI | KPI reporting, trends, segmentation, and operational analysis |

## Technical Approach

The analysis was built as a controlled SQL Server workflow, with business rules and KPI calculations implemented before Power BI consumption.

### 1. Source Ingestion

Source extracts are landed in the RAW layer to preserve source-faithful data and support traceability and reloadability.

### 2. Data Quality & Standardisation

The STG layer converts raw values into analytical data types, standardises source fields, validates business keys and timestamps, and isolates structural rejects for review.

### 3. Business Integration

The CORE layer integrates telemetry, incidents, service visits, device attributes, and SLA contracts into conformed dimensions and operational facts. Surrogate keys and relationships are resolved here.

### 4. KPI & Business Rule Processing

Contractual SLA thresholds, in-scope availability rules, penalty logic, restoration measures, and field-service quality measures are applied before analytical consumption.

### 5. Analytical Mart

The MART layer produces reporting-ready facts and views at defined analytical grains, including device-month availability and account × SLA tier × month SLA/penalty analysis.

### 6. Validation & Reconciliation

The pipeline includes row-count checks, grain uniqueness checks, minute reconciliation, KPI smoke tests, and controls to verify that percentage metrics are calculated from the appropriate underlying measures.

### 7. Power BI Consumption

Power BI consumes the governed analytical outputs to provide executive KPI reporting, trends, account and tier analysis, and operational performance views.

## Data Scale & KPI Framework

The analysis covers a 24-month operational period across approximately 900 ATMs and seven banking accounts.

| Area | Scale / KPI |
|---|---:|
| ATMs | ~900 |
| Banking accounts | 7 |
| SLA contract terms | 84 |
| Incidents | 28,107 |
| Service visits | 19,100 |
| Telemetry events | 2,786,490 |
| Reporting period | 24 months |

### Core KPIs

| KPI | Result |
|---|---:|
| Technical (In-Scope) Availability | **98.37%** |
| SLA Compliance | **90.77%** |
| Penalty Accrued | **2.48M EGP** |
| Penalty Realised | **2.36M EGP** |
| Median MTTR | **379 min** |
| P90 MTTR | **1,299 min** |
| First-Time Fix Rate (FTFR) | **79.44%** |
| Repeat Visit Rate | **20.56%** |

### KPI Design

- **Availability** is calculated from minute-weighted in-scope uptime and total minutes.
- **SLA Compliance** is evaluated against the applicable account × SLA tier × month contractual threshold.
- **Penalty Accrued** separates accrued exposure from realised penalties for closed periods.
- **MTTR** uses both Median and P90 to capture typical restoration performance and the long tail.
- **FTFR and Repeat Visit Rate** are analysed together to assess field-service quality.

## Power BI Report

The Power BI report translates the governed analytical outputs into four decision-oriented views:

| Report Page | Focus |
|---|---|
| Executive Overview | Overall availability, SLA compliance, penalty exposure, and operational performance |
| ATM Availability | Availability trends, device performance, and downtime analysis |
| SLA Compliance & Penalties | Contract compliance, penalty exposure, and account × SLA tier analysis |
| Incident Operations | Incident volume, restoration performance, MTTR, FTFR, and repeat visits |

The report supports filtering and segmentation across reporting periods, accounts, SLA tiers, regions, vendors, and ATM-level operational dimensions.


## Key Insights & Recommendations

### 1. SLA Compliance Gap
**98.37% Technical Availability vs 90.77% SLA Compliance**

- **Implication:** Fleet availability alone does not capture contractual performance.
- **Action:** Investigate failing account × SLA tier × month combinations.

### 2. Restoration Drives Financial Exposure

**1.98M EGP Restoration Penalty vs 495K EGP Availability Penalty | Response Penalty: 0 EGP**

- **Implication:** Financial exposure is concentrated in restoration performance.
- **Action:** Prioritize Restoration SLA breaches and prolonged incidents.

### 3. Field-Service Quality Below Target
**FTFR: 79.44% vs ≥85% | Repeat Visit Rate: 20.56% vs ≤15%**

- **Implication:** Repeat dispatches indicate a service-quality gap.
- **Action:** Analyze repeat visits by vendor, region, and incident characteristics.

### 4. Significant MTTR Long Tail
**Median MTTR: 379 min | P90 MTTR: 1,299 min**

- **Implication:** A smaller group of prolonged incidents creates disproportionate SLA risk.
- **Action:** Investigate high-duration incidents and recurring restoration patterns.

### 5. Material Vendor Performance Variation
**FTFR: 91.30%–61.43% | Repeat Visit Rate: 8.70%–38.57%**

- **Implication:** Fleet averages can hide underperforming vendors.
- **Action:** Establish targeted improvement plans for weak-performing vendors.

### 6. Episodic SLA Deterioration
**Notable periods: May–June 2025 and February 2026**

- **Implication:** Performance deterioration is concentrated in specific periods rather than continuously declining.
- **Action:** Drill into account × SLA tier × month during these periods.

> **Note:** Response Penalty = **0 EGP** under the approved Response SLA logic; this does **not** mean Response Time = 0.

