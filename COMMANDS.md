# COMMANDS.md — Every CLI Command in Exact Order

> Run these in order. Each section depends on the previous one completing successfully.

---

## SECTION 1 — Bootstrap (one-time manual setup)

```bash
# 1.1 Login and set subscription
az login
az account set --subscription "YOUR-SUBSCRIPTION-ID"
az account show  # verify correct subscription

# 1.2 Create Service Principal for Terraform + CI/CD
az ad sp create-for-rbac \
  --name "sp-dr-automation" \
  --role "Contributor" \
  --scopes "/subscriptions/YOUR-SUBSCRIPTION-ID" \
  --sdk-auth
# SAVE THE OUTPUT — clientSecret cannot be retrieved again

# 1.3 Create resource group for Terraform state
az group create --name rg-tfstate --location eastus

# 1.4 Create storage account for Terraform remote state
az storage account create \
  --name sttfstatemyapp001 \
  --resource-group rg-tfstate \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2

# 1.5 Create containers for state files
az storage container create \
  --name tfstate-primary \
  --account-name sttfstatemyapp001

az storage container create \
  --name tfstate-dr \
  --account-name sttfstatemyapp001

# 1.6 Create Azure Container Registry (Premium for geo-replication)
az acr create \
  --name acrmyapp001 \
  --resource-group rg-tfstate \
  --sku Premium \
  --location eastus

# 1.7 Geo-replicate ACR to DR region
az acr replication create \
  --registry acrmyapp001 \
  --location westeurope

# 1.8 Create Key Vault for secrets
az keyvault create \
  --name kv-myapp-global \
  --resource-group rg-tfstate \
  --location eastus

# 1.9 Store secrets in Key Vault
az keyvault secret set --vault-name kv-myapp-global \
  --name "SP-CLIENT-ID" --value "YOUR-CLIENT-ID"
az keyvault secret set --vault-name kv-myapp-global \
  --name "SP-CLIENT-SECRET" --value "YOUR-CLIENT-SECRET"
az keyvault secret set --vault-name kv-myapp-global \
  --name "SP-TENANT-ID" --value "YOUR-TENANT-ID"
az keyvault secret set --vault-name kv-myapp-global \
  --name "DB-ADMIN-PASSWORD" --value "YourStr0ngP@ssw0rd!"
```

---

## SECTION 2 — Deploy Primary Region (Terraform)

```bash
# 2.1 Navigate to primary environment
cd infra/envs/primary

# 2.2 Create backend config file
cat > backend.hcl << 'BACKEND'
resource_group_name  = "rg-tfstate"
storage_account_name = "sttfstatemyapp001"
container_name       = "tfstate-primary"
key                  = "primary.terraform.tfstate"
BACKEND

# 2.3 Initialize Terraform
terraform init -backend-config=backend.hcl

# 2.4 Set ARM environment variables
export ARM_CLIENT_ID="YOUR-CLIENT-ID"
export ARM_CLIENT_SECRET="YOUR-CLIENT-SECRET"
export ARM_TENANT_ID="YOUR-TENANT-ID"
export ARM_SUBSCRIPTION_ID="YOUR-SUBSCRIPTION-ID"

# 2.5 Plan and review
terraform plan \
  -var-file=primary.auto.tfvars \
  -var="db_admin_password=YourStr0ngP@ssw0rd!" \
  -out=tfplan-primary

# 2.6 Apply (creates East US infrastructure)
terraform apply tfplan-primary

# 2.7 Save outputs for DR env
terraform output -raw aks_ingress_ip > /tmp/primary_ingress_ip.txt
terraform output -raw sql_server_id > /tmp/primary_sql_id.txt
echo "Primary AKS IP: $(cat /tmp/primary_ingress_ip.txt)"
echo "Primary SQL ID: $(cat /tmp/primary_sql_id.txt)"
```

---

## SECTION 3 — Deploy DR Region (Terraform)

```bash
# 3.1 Navigate to DR environment
cd infra/envs/dr

# 3.2 Create backend config
cat > backend.hcl << 'BACKEND'
resource_group_name  = "rg-tfstate"
storage_account_name = "sttfstatemyapp001"
container_name       = "tfstate-dr"
key                  = "dr.terraform.tfstate"
BACKEND

# 3.3 Update dr.auto.tfvars with primary outputs
PRIMARY_SQL_ID=$(cat /tmp/primary_sql_id.txt)
sed -i "s|primary_sql_server_id.*|primary_sql_server_id = \"$PRIMARY_SQL_ID\"|" dr.auto.tfvars

# 3.4 Initialize and apply
terraform init -backend-config=backend.hcl
terraform plan \
  -var-file=dr.auto.tfvars \
  -var="db_admin_password=YourStr0ngP@ssw0rd!" \
  -out=tfplan-dr
terraform apply tfplan-dr

# 3.5 Save DR outputs
terraform output -raw dr_aks_ingress_ip > /tmp/dr_ingress_ip.txt
terraform output -raw dr_sql_server_id > /tmp/dr_sql_id.txt

# 3.6 Update primary with DR outputs (SQL Failover Group needs DR server ID)
cd infra/envs/primary
DR_SQL_ID=$(cat /tmp/dr_sql_id.txt)
terraform apply \
  -var-file=primary.auto.tfvars \
  -var="db_admin_password=YourStr0ngP@ssw0rd!" \
  -var="dr_sql_server_id=$DR_SQL_ID" \
  -auto-approve
```

---

## SECTION 4 — Install ArgoCD + Configure GitOps

```bash
# 4.1 Get AKS credentials for both clusters
az aks get-credentials \
  --resource-group rg-myapp-primary \
  --name aks-myapp-primary \
  --alias primary

az aks get-credentials \
  --resource-group rg-myapp-dr \
  --name aks-myapp-dr \
  --alias dr

# 4.2 Verify both contexts
kubectl config get-contexts

# 4.3 Install ArgoCD on primary cluster
kubectl create namespace argocd --context primary
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --context primary

# 4.4 Wait for ArgoCD to be ready
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=300s --context primary

# 4.5 Get ArgoCD initial password
ARGOCD_PASS=$(argocd admin initial-password -n argocd --context primary | head -1)
echo "ArgoCD password: $ARGOCD_PASS"

# 4.6 Get ArgoCD server IP
ARGOCD_IP=$(kubectl get svc argocd-server -n argocd --context primary \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 4.7 Login to ArgoCD CLI
argocd login $ARGOCD_IP \
  --username admin \
  --password $ARGOCD_PASS \
  --insecure

# 4.8 Register both clusters in ArgoCD
argocd cluster add primary --name primary-eastus
argocd cluster add dr --name dr-westeurope

# 4.9 Verify clusters registered
argocd cluster list

# 4.10 Create production namespace in both clusters
kubectl create namespace production --context primary
kubectl create namespace production --context dr

# 4.11 Create DB secret in both clusters
kubectl create secret generic db-secret \
  --from-literal=password="YourStr0ngP@ssw0rd!" \
  -n production --context primary

kubectl create secret generic db-secret \
  --from-literal=password="YourStr0ngP@ssw0rd!" \
  -n production --context dr

# 4.12 Deploy ApplicationSet (deploys app to both clusters)
kubectl apply -f k8s/argocd/applicationset.yaml -n argocd --context primary

# 4.13 Watch sync status
argocd app list
watch -n5 'argocd app list'
```

---

## SECTION 5 — Verify Full Setup

```bash
# 5.1 Check both AKS clusters are healthy
kubectl get nodes --context primary
kubectl get nodes --context dr

# 5.2 Check all pods running in both clusters
kubectl get pods -n production --context primary
kubectl get pods -n production --context dr

# 5.3 Check ArgoCD shows both apps synced
argocd app list
# Expected: both show STATUS=Synced HEALTH=Healthy

# 5.4 Check Front Door sees both backends healthy
az network front-door backend-pool show \
  --front-door-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --name app-pool \
  --query "backends[].{address:address,enabled:enabledState}" \
  -o table

# 5.5 Check SQL Failover Group replication state
az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary \
  --query "{state:replicationState,role:role}" \
  -o table
# Expected: state=CATCH_UP, role=Primary

# 5.6 Hit the public URL and verify region
curl -s https://app.yourcompany.com/health | python3 -m json.tool
# Expected: {"status":"healthy","region":"eastus"}

# 5.7 Verify x-azure-ref header (confirms Front Door in path)
curl -v https://app.yourcompany.com/health 2>&1 | grep x-azure-ref
```

---

## SECTION 6 — DR Drill (Run Quarterly)

```bash
# 6.1 Announce to team before starting
echo "Starting DR drill at $(date). Notifying team..."

# 6.2 Disable primary backend in Front Door (NO real outage)
az afd origin update \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --origin-group-name app-origin-group \
  --origin-name primary-east-us \
  --enabled-state Disabled

# 6.3 Watch traffic shift (should change from eastus to westeurope)
watch -n 5 'curl -s https://app.yourcompany.com/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[\"region\"], d[\"status\"])"'
# Wait for: westeurope healthy

# 6.4 Verify DR DB was promoted
watch -n 10 'az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-dr \
  --server sql-myapp-dr \
  --query "replicationRole" -o tsv'
# Wait for: Secondary → Primary

# 6.5 Check DR pods scaled up
kubectl get pods -n production --context dr
kubectl get hpa -n production --context dr

# 6.6 Record actual RTO
DRILL_END=$(date +%s)
echo "Traffic on DR. Measure time from step 6.2 to this line = your real RTO"

# 6.7 Restore primary (FAILBACK)
az afd origin update \
  --profile-name afd-myapp-global \
  --resource-group rg-myapp-primary \
  --origin-group-name app-origin-group \
  --origin-name primary-east-us \
  --enabled-state Enabled

# Wait for primary to recover health probes (~90s)
sleep 120

# 6.8 Failback SQL to original primary
az sql failover-group set-primary \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary

# 6.9 Scale DR back to warm standby
az aks scale \
  --resource-group rg-myapp-dr \
  --name aks-myapp-dr \
  --node-count 2

kubectl patch hpa frontend-hpa -n production --context dr \
  -p '{"spec":{"minReplicas":2}}'
kubectl patch hpa api-hpa -n production --context dr \
  -p '{"spec":{"minReplicas":2}}'

# 6.10 Verify back to primary
curl -s https://app.yourcompany.com/health | python3 -m json.tool
# Expected: {"status":"healthy","region":"eastus"}
echo "DR drill complete. Document your RTO."
```

---

## SECTION 7 — Useful Day-2 Commands

```bash
# Check replication lag
az sql failover-group show \
  --name fog-myapp \
  --resource-group rg-myapp-primary \
  --server sql-myapp-primary \
  --query "replicationState"

# Force ArgoCD sync both clusters
argocd app sync app-primary-eastus
argocd app sync app-dr-westeurope

# Check ArgoCD drift
argocd app diff app-primary-eastus
argocd app diff app-dr-westeurope

# Scale DR node pool manually
az aks scale --resource-group rg-myapp-dr \
  --name aks-myapp-dr --node-count 5

# View Automation Runbook job history
az automation job list \
  --automation-account-name aa-myapp-dr-failover \
  --resource-group rg-myapp-primary \
  -o table

# Check Front Door health percentages
az monitor metrics list \
  --resource /subscriptions/SUB_ID/resourceGroups/rg-myapp-primary/providers/Microsoft.Cdn/profiles/afd-myapp-global \
  --metric OriginHealthPercentage \
  --interval PT1M \
  -o table

# Terraform destroy DR (cost saving when not needed)
cd infra/envs/dr
terraform destroy -var-file=dr.auto.tfvars -auto-approve
```
