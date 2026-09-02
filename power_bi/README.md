# Power BI Report

The Power BI report translates the governed analytical outputs from the SQL Server warehouse into four decision-oriented views focused on SLA performance, availability, financial exposure, and field-service operations.

## Report Pages

| Report Page | Focus |
|---|---|
| Executive Overview | Overall availability, SLA compliance, penalty exposure, and operational performance |
| ATM Availability | Availability trends, device performance, and downtime analysis |
| SLA Compliance & Penalties | Contract compliance, penalty exposure, and account × SLA tier analysis |
| Incident Operations | Incident volume, restoration performance, MTTR, FTFR, and repeat visits |

## Reporting Scope

The report supports analysis across:

- Reporting periods
- Banking accounts
- SLA tiers
- Regions
- Vendors
- ATM-level operational dimensions

## Key KPIs

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

## Report Screenshots

### Executive Overview

![Executive Overview](screenshots/executive_overview.png)

### ATM Availability

![ATM Availability](screenshots/atm_availability.png)

### SLA Compliance & Penalties

![SLA Compliance & Penalties](screenshots/sla_compliance_penalties.png)

### Incident Operations

![Incident Operations](screenshots/incident_operations.png)
