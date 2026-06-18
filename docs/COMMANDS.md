# COMMANDS.md — Every CLI Command in Order

> Complete step-by-step commands to build the entire DR architecture from scratch.  
> Run these in order. Each section builds on the previous.

---

## PHASE 0 — Prerequisites check

```bash
# Verify all tools installed
az --version           # Need >= 2.50
terraform --version    # Need >= 1.6
kubectl version        # Need >= 1.28
argocd version         # Need >= 2.8
docker --version       # Any recent version

# Login to Azure
az login
az account list --output table

# Set your subscription
export SUBSCRIPTION_ID="YOUR-SUBSCRIPTION-ID"
az account set --subscription $SUBSCRIPTION_ID

# Verify you have Contributor access
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --output table
```

---

## PHASE 1 — Bootstrap (run ONCE manually)

```bash
# ── Create resource group for shared infrastructure ──────────
az group create \
  --name rg-dr-bootstrap \
  --location eastus

# ── Create Service Principal for Terraform + Azure DevOps ────
# SAVE the output — clientSecret shown only once
az ad sp create-for-rbac \
  --name "sp-dr-cicd" \
  --role "Contributor" \
  --scopes "/subscriptions/$SUBSCRIPTION_ID" \
  --sdk-auth > sp-credentials.json

cat sp-credentials.json
# Export these for use in next commands:
export ARM_CLIENT_ID=$(cat sp-credentials.json | python3 -c "import sys,json; print(json.load(sys.stdin)['clientId'])")
export ARM_CLIENT_SECRET=$(cat sp-credentials.json | python3 -c "import sys,json; print(json.load(sys.stdin)['clientSecret'])")
export ARM_TENANT_ID=$(cat sp-credentials.json | python3 -c "import sys,json; print(json.load(sys.stdin)['tenantId'])")

# ── Create Terraform remote state storage ────────────────────
# Storage account name must be globally unique — change myapp001
az storage account create \
  --name sttfstatemyapp001 \
  --resource-group rg-dr-bootstrap \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2

az storage container create \
  --name tfstate-primary \
  --account-name sttfstatemyapp001

az storage container create \
  --name tfstate-dr \
  --account-name sttfstatemyapp001

# ── Create Azure Container Registry (geo-replicated) ─────────
# Must be Premium SKU for geo-replication
az acr create \
  --name acrmyapp001 \
  --resource-group rg-dr-bootstrap \
  --sku Premium \
  --location eastus \
  --admin-enabled false

# Replicate to DR region
az acr replication create \
  --registry acrmyapp001 \
  --location westeurope

# Verify replication
az acr replication list --registry acrmyapp001 --output table

# ── Create Key Vault for secrets ─────────────────────────────
az keyvault create \
  --name kv-myapp-global \
  --resource-group rg-dr-bootstrap \
  --location eastus \
  --sku standard \
  --enable-rbac-authorization false

# Store SP credentials in Key Vault
az keyvault secret set --vault-name kv-myapp-global \
  --name "SP-CLIENT-ID"       --value "$ARM_CLIENT_ID"
az keyvault secret set --vault-name kv-myapp-global \
  --name "SP-CLIENT-SECRET"   --value "$ARM_CLIENT_SECRET"
az keyvault secret set --vault-name kv-myapp-global \
  --name "SP-TENANT-ID"       --value "$ARM_TENANT_ID"
az keyvault secret set --vault-name kv-myapp-global \
  --name "DB-ADMIN-PASSWORD"  --value "YourStr0ngP@ssw0rd2024!"
az keyvault secret set --vault-name kv-myapp-global \
  --name "SLACK-WEBHOOK"      --value "https://hooks.slack.com/YOUR-WEBHOOK"

echo "Bootstrap complete. Never run this phase again."
```

---

## PHASE 2 — Terraform: Deploy primary region

```bash
cd infra/envs/primary

# Initialise Terraform with remote state
terraform init \
  -backend-config="storage_account_name=sttfstatemyapp001" \
  -backend-config="container_name=tfstate-primary" \
  -backend-config="key=primary.terraform.tfstate" \
  -backend-config="resource_group_name=rg-dr-bootstrap"

# Review what will be created
terraform plan \
  -var="arm_client_id=$ARM_CLIENT_ID" \
  -var="arm_client_secret=$ARM_CLIENT_SECRET" \
  -var="arm_tenant_id=$ARM_TENANT_ID" \
  -var="arm_subscription_id=$SUBSCRIPTION_ID" \
  -var="db_admin_password=YourStr0ngP@ssw0rd2024!" \
  -out=primary.tfplan

# Apply (creates all primary region resources)
terraform apply primary.tfplan

# Save outputs for DR env
export PRIMARY_SQL_SERVER_ID=$(terraform output -raw sql_server_id)
export PRIMARY_VNET_ID=$(terraform output -raw vnet_id)
echo "Primary SQL Server ID: $PRIMARY_SQL_SERVER_ID"
```

---

## PHASE 3 — Terraform: Deploy DR region

```bash
cd ../dr

terraform init \
  -backend-config="storage_account_name=sttfstatemyapp001" \
  -backend-config="container_name=tfstate-dr" \
  -backend-config="key=dr.terraform.tfstate" \
  -backend-config="resource_group_name=rg-dr-bootstrap"

terraform plan \
  -var="arm_client_id=$ARM_CLIENT_ID" \
  -var="arm_client_secret=$ARM_CLIENT_SECRET" \
  -var="arm_tenant_id=$ARM_TENANT_ID" \
  -var="arm_subscription_id=$SUBSCRIPTION_ID" \
  -var="db_admin_password=YourStr0ngP@ssw0rd2024!" \
  -var="primary_sql_server_id=$PRIMARY_SQL_SERVER_ID" \
  -out=dr.tfplan

terraform apply dr.tfplan

# Save DR outputs for later
export DR_AKS_INGRESS_IP=$(terraform output -raw aks_ingress_ip)
export DR_SQL_SERVER_ID=$(terraform output -raw sql_server_id)
echo "DR AKS Ingress IP: $DR_AKS_INGRESS_IP"
```

---

## PHASE 4 — SQL Failover Group

```bash
# Create failover group linking primary and DR SQL servers
az sql failover-group create \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary \
  --partner-resource-group rg-myapp-dr \
  --partner-server sql-myapp-dr \
  --failover-policy Automatic \
  --grace-period 1

# Verify failover group created correctly
az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary \
  --query "{state:replicationState, role:replicationRole}" \
  --output table

# Expected output:
# state        role
# ----------   -------
# CATCH_UP     Primary
```

---

## PHASE 5 — AKS setup and ArgoCD

```bash
# ── Get credentials for both clusters ────────────────────────
az aks get-credentials \
  --resource-group rg-myapp-primary \
  --name aks-myapp-primary \
  --context primary \
  --overwrite-existing

az aks get-credentials \
  --resource-group rg-myapp-dr \
  --name aks-myapp-dr \
  --context dr \
  --overwrite-existing

# Verify both clusters accessible
kubectl get nodes --context primary
kubectl get nodes --context dr

# ── Attach ACR to both AKS clusters ──────────────────────────
ACR_ID=$(az acr show --name acrmyapp001 --query id -o tsv)

az aks update \
  --resource-group rg-myapp-primary \
  --name aks-myapp-primary \
  --attach-acr $ACR_ID

az aks update \
  --resource-group rg-myapp-dr \
  --name aks-myapp-dr \
  --attach-acr $ACR_ID

# ── Install ArgoCD on PRIMARY cluster ────────────────────────
kubectl create namespace argocd --context primary

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --context primary

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=120s --context primary

# Get initial admin password
ARGOCD_PASS=$(argocd admin initial-password \
  -n argocd --context primary | head -1)
echo "ArgoCD password: $ARGOCD_PASS"

# Get ArgoCD server IP
ARGOCD_IP=$(kubectl get svc argocd-server -n argocd \
  --context primary \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Login to ArgoCD CLI
argocd login $ARGOCD_IP \
  --username admin \
  --password $ARGOCD_PASS \
  --insecure

# ── Register both clusters in ArgoCD ─────────────────────────
argocd cluster add primary --name primary-eastus
argocd cluster add dr --name dr-westeurope

# Verify both clusters registered
argocd cluster list

# ── Deploy ArgoCD ApplicationSet ─────────────────────────────
kubectl apply -f k8s/argocd/applicationset.yaml \
  -n argocd --context primary

# Wait for both apps to sync
argocd app wait app-primary-eastus --health --timeout 300
argocd app wait app-dr-westeurope  --health --timeout 300

# Verify both apps
argocd app list
```

---

## PHASE 6 — Azure Monitor alerts + Automation Runbook

```bash
# ── Create Automation Account ─────────────────────────────────
az automation account create \
  --resource-group rg-myapp-primary \
  --name aa-myapp-dr-failover \
  --location eastus \
  --sku Basic

# Enable Managed Identity
az automation account update \
  --resource-group rg-myapp-primary \
  --name aa-myapp-dr-failover \
  --assign-identity SystemAssigned

# Get Managed Identity Object ID
MSI_ID=$(az automation account show \
  --resource-group rg-myapp-primary \
  --name aa-myapp-dr-failover \
  --query identity.principalId -o tsv)
echo "MSI Object ID: $MSI_ID"

# Grant Contributor on DR resource group ONLY (least privilege)
az role assignment create \
  --assignee $MSI_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-myapp-dr"

# Grant Reader on primary (to check status)
az role assignment create \
  --assignee $MSI_ID \
  --role "Reader" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-myapp-primary"

# ── Upload Runbook ────────────────────────────────────────────
az automation runbook create \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --name runbook-dr-failover-scale \
  --type PowerShell \
  --log-verbose true \
  --log-progress true

az automation runbook replace-content \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --name runbook-dr-failover-scale \
  --content @infra/modules/automation/runbook.ps1

az automation runbook publish \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --name runbook-dr-failover-scale

# ── Create webhook for Runbook ────────────────────────────────
# SAVE the URI — shown only once
az automation webhook create \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --runbook-name runbook-dr-failover-scale \
  --name webhook-dr-failover \
  --expiry-time "2030-01-01T00:00:00Z" \
  --is-enabled true

# Store webhook URI in Key Vault
WEBHOOK_URI=$(az automation webhook show \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --name webhook-dr-failover \
  --query uri -o tsv)

az keyvault secret set \
  --vault-name kv-myapp-global \
  --name "RUNBOOK-WEBHOOK-URI" \
  --value "$WEBHOOK_URI"

# ── Create Action Group ───────────────────────────────────────
az monitor action-group create \
  --resource-group rg-myapp-primary \
  --name ag-dr-failover-trigger \
  --short-name drfailover \
  --action webhook dr-runbook "$WEBHOOK_URI" --use-common-alert-schema true \
  --action email oncall "oncall@yourcompany.com" --use-common-alert-schema true

# ── Create Alert Rule ─────────────────────────────────────────
AFD_ID=$(az afd profile show \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --query id -o tsv)

ACTION_GROUP_ID=$(az monitor action-group show \
  --resource-group rg-myapp-primary \
  --name ag-dr-failover-trigger \
  --query id -o tsv)

az monitor metrics alert create \
  --resource-group rg-myapp-primary \
  --name alert-primary-region-down \
  --scopes $AFD_ID \
  --condition "avg OriginHealthPercentage < 100" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --severity 0 \
  --action $ACTION_GROUP_ID \
  --description "Primary region unhealthy — triggers DR failover runbook"
```

---

## PHASE 7 — DNS and Front Door verification

```bash
# ── Verify Front Door sees both backends as healthy ───────────
az afd origin list \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --origin-group-name app-origin-group \
  --query "[].{name:name,host:hostName,enabled:enabledState}" \
  --output table

# ── Point your custom domain to Front Door ────────────────────
# In your DNS provider (Azure DNS, Cloudflare, Route53 etc):
# CNAME  app.yourcompany.com  →  afd-myapp-global.azurefd.net

# Verify traffic is routing through Front Door:
curl -v https://app.yourcompany.com/health
# Look for x-azure-ref header — confirms Front Door is in the path
# Response should show: {"status":"healthy","region":"eastus"}

# ── Verify DB replication is active ──────────────────────────
az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary \
  --query "{state:replicationState,role:replicationRole}" \
  --output table
# Expected: state=CATCH_UP, role=Primary
```

---

## PHASE 8 — DR Drill (run quarterly)

```bash
# !! Announce to team before running !!
# !! Run during low-traffic hours !!

echo "=== DR DRILL STARTED: $(date) ==="

# Step 1: Disable primary in Front Door (no real outage)
az afd origin update \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --origin-group-name app-origin-group \
  --origin-name primary-east-us \
  --enabled-state Disabled

echo "Primary disabled in Front Door. Watching for failover..."
DRILL_START=$(date +%s)

# Step 2: Watch traffic shift to DR (expect ~60–90 seconds)
watch -n 5 'echo "--- $(date) ---" && curl -s https://app.yourcompany.com/health | python3 -m json.tool'
# Press Ctrl+C when you see region flip to "westeurope"

DRILL_END=$(date +%s)
echo "Failover detected after $((DRILL_END - DRILL_START)) seconds"

# Step 3: Verify all 3 tiers in DR
kubectl get pods -n production --context dr
kubectl get hpa -n production --context dr

# Step 4: Check DB was promoted
az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-dr \
  --server sql-myapp-dr \
  --query "replicationRole" -o tsv
# Expected: Primary

# Step 5: Run smoke test against DR directly
DR_IP=$(kubectl get svc frontend-svc -n production --context dr \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$DR_IP/health

# Step 6: Restore primary (failback)
az afd origin update \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --origin-group-name app-origin-group \
  --origin-name primary-east-us \
  --enabled-state Enabled

# Wait for SQL replication to catch up before failing back DB
sleep 120

# Failback SQL to original primary
az sql failover-group set-primary \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary

# Scale DR back to warm standby
kubectl patch hpa frontend-hpa -n production \
  -p '{"spec":{"minReplicas":2}}' --context dr
kubectl patch hpa api-hpa -n production \
  -p '{"spec":{"minReplicas":2}}' --context dr

az aks scale \
  --resource-group rg-myapp-dr \
  --name aks-myapp-dr \
  --node-count 2

echo "=== DR DRILL COMPLETE: $(date) ==="
echo "Measured RTO: $((DRILL_END - DRILL_START)) seconds"
```

---

## Useful day-to-day commands

```bash
# Check ArgoCD sync status for both clusters
argocd app list

# Force ArgoCD sync (if git push didn't auto-trigger)
argocd app sync app-primary-eastus
argocd app sync app-dr-westeurope

# Check pod counts in both regions
kubectl get pods -n production --context primary
kubectl get pods -n production --context dr

# Check HPA status
kubectl get hpa -n production --context primary
kubectl get hpa -n production --context dr

# Check SQL replication lag (run on DR side)
az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-dr \
  --server sql-myapp-dr \
  --query "replicationState" -o tsv

# Check Front Door health of both backends
az afd origin list \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --origin-group-name app-origin-group \
  --output table

# Check Automation Runbook job history
az automation job list \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --output table

# Manually trigger Runbook (for testing)
az automation runbook start \
  --resource-group rg-myapp-primary \
  --automation-account-name aa-myapp-dr-failover \
  --name runbook-dr-failover-scale

# Terraform plan for infra changes
cd infra/envs/primary
terraform plan -var-file=primary.auto.tfvars

# Destroy DR region (cost saving in dev)
cd infra/envs/dr
terraform destroy -var-file=dr.auto.tfvars -auto-approve
```

---

*Samarjeet Singh · DevOps Engineer · HCLTech · AZ-104*
