# Azure Multi-Region DR Architecture — 3-Tier App · Zero Human Failover

> **RTO: ~90 seconds · RPO: ~5 seconds · Human steps during failover: 0**

**Samarjeet Singh** — DevOps Engineer · AZ-104 · HCLTech

---

## Architecture

```
Users → app.company.com
           │
           ▼
   ┌─ Azure Front Door ──────────────────────────────┐
   │  Health probe /health every 30s                  │
   │  2 failures → DNS flip to DR (AUTOMATIC)         │
   └────────┬───────────────────────┬────────────────┘
            │ priority=1            │ priority=2
            ▼                       ▼
  ┌── East US (Primary) ──┐  ┌── West Europe (DR) ───┐
  │  Tier 1: Frontend AKS │  │  Tier 1: Frontend AKS │
  │  Tier 2: API AKS      │  │  Tier 2: API AKS      │
  │  Tier 3: SQL Primary  │◄─►  Tier 3: SQL Replica  │
  │  (5 pods · full load) │  │  (2 pods · warm)      │
  └───────────────────────┘  └───────────────────────┘
           async geo-replication lag ~2s
```

**Failover chain — zero human steps:**
- T=0s   Primary /health stops responding
- T=30s  Front Door probe #1 fails (automatic)
- T=60s  Front Door probe #2 fails — threshold crossed (automatic)
- T=62s  DNS flips to DR — Azure Front Door (automatic)
- T=65s  SQL replica promoted — SQL Failover Group (automatic)
- T=70s  Runbook scales DR pods 2→5 — Automation MSI (automatic)
- T=90s  All 3 tiers live in West Europe
- T=95s  Slack: "Failover complete. No action needed."

---

## Repo structure

```
azure-dr-architecture/
├── infra/
│   ├── modules/aks/            # AKS cluster module
│   ├── modules/sql/            # Azure SQL + Failover Group
│   ├── modules/frontdoor/      # Azure Front Door
│   ├── modules/automation/     # Runbook + Managed Identity + RBAC
│   ├── modules/monitoring/     # Azure Monitor alerts + Action Groups
│   ├── envs/primary/           # East US — full production
│   └── envs/dr/                # West Europe — warm standby
├── k8s/
│   ├── base/                   # Shared manifests + HPA
│   ├── overlays/primary/       # replicas=5, region=eastus
│   ├── overlays/dr/            # replicas=2, region=westeurope
│   └── argocd/                 # ApplicationSet both clusters
├── pipelines/
│   ├── app-ci.yml              # Build + test + push ACR
│   ├── app-cd.yml              # Verify deploy primary + DR
│   ├── infra-primary.yml       # Terraform apply primary
│   ├── infra-dr.yml            # Terraform apply DR
│   └── failback.yml            # Manual failback (approval gate)
├── app/
│   ├── frontend/               # Node.js frontend + /health
│   └── api/                    # Node.js API + /health
├── runbook/
│   └── dr-failover.ps1         # Azure Automation PowerShell Runbook
├── docs/architecture.md
├── COMMANDS.md                 # Every CLI command in exact order
└── README.md
```

---

## Quick start

See **COMMANDS.md** for every command with exact syntax in order.

```bash
# 1. Bootstrap (one-time)
az login && az account set --subscription "SUB-ID"

# 2. Deploy primary
cd infra/envs/primary && terraform init && terraform apply

# 3. Deploy DR
cd infra/envs/dr && terraform init && terraform apply

# 4. Install ArgoCD + register clusters
argocd cluster add aks-primary --name primary-eastus
argocd cluster add aks-dr --name dr-westeurope
kubectl apply -f k8s/argocd/applicationset.yaml -n argocd

# 5. Run DR drill
az afd origin update --enabled-state Disabled ...
watch -n5 'curl -s https://app.company.com/health'
```

---

## Key rule — /health endpoint

```javascript
// MUST return 503 when DB/cache is down — not always 200
app.get('/health', async (req, res) => {
  try {
    await db.query('SELECT 1');
    await redis.ping();
    res.status(200).json({ status: 'healthy', region: process.env.REGION });
  } catch (err) {
    res.status(503).json({ status: 'unhealthy', error: err.message });
  }
});
```

---

## Stack

Azure Front Door · AKS · Azure SQL Failover Group · Azure Automation (MSI) ·
Azure Monitor · Terraform · Terragrunt · ArgoCD ApplicationSet · Kustomize ·
Prometheus · Alertmanager · Azure DevOps CI/CD · ACR (geo-replicated) · Azure Key Vault
