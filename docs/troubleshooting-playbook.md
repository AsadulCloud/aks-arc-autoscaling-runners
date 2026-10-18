# End-to-End Guide: Autoscaling GitHub Actions Runners on AKS with ARC & Prometheus

This guide provides the complete, production-ready implementation of an autoscaling, ephemeral GitHub Actions runner fleet on Azure Kubernetes Service (AKS) using Actions Runner Controller (ARC) and Prometheus. It also documents every blocker and schema issue encountered during deployment, explaining the root causes and permanent resolutions.

---

## Table of Contents
1. [Architecture & Concept](#1-architecture--concept)
2. [Prerequisites & Scope Setup](#2-prerequisites--scope-setup)
3. [All Production Configuration Files](#3-all-production-configuration-files)
   - [Terraform: Provider & Versions (`versions.tf`)](#terraform-provider--versions-versionstf)
   - [Terraform: Main AKS Cluster Infrastructure (`main.tf`)](#terraform-main-aks-cluster-infrastructure-maintf)
   - [Terraform: Input Variables (`variables.tf`)](#terraform-input-variables-variablestf)
   - [Terraform: Outputs (`outputs.tf`)](#terraform-outputs-outputstf)
   - [Helm Values: ARC Scale Set (`arc-values.yaml`)](#helm-values-arc-scale-set-arc-valuesyaml)
   - [Kubernetes: Metrics Services (`metrics-services.yaml`)](#kubernetes-metrics-services-metrics-servicesyaml)
   - [Helm Values: Prometheus Scrape Config (`prometheus-extra-scrape.yaml`)](#helm-values-prometheus-scrape-config-prometheus-extra-scrapeyaml)
   - [GitHub Actions: Multi-Pod Stress Workflow (`.github/workflows/arc-test.yml`)](#github-actions-multi-pod-stress-workflow-githubworkflowsarc-testyml)
4. [Step-by-Step Deployment Runbook](#4-step-by-step-deployment-runbook)
5. [Every Issue Encountered, Why It Happened & The Fix](#5-every-issue-encountered-why-it-happened--the-fix)
6. [Telemetry & Verification Guide](#6-telemetry--verification-guide)
7. [Teardown & Clean Up (Stop Azure Billing)](#7-teardown--clean-up-stop-azure-billing)

---

## 1. Architecture & Concept

Instead of paying for expensive GitHub-hosted runner minutes or keeping static Azure Virtual Machines idling 24/7, Actions Runner Controller (ARC) uses an event-driven Kubernetes architecture:

```
+---------------------------------------------------------------------------------------------------+
| Azure Kubernetes Service (AKS)                                                                    |
|                                                                                                   |
|  +---------------------------+     Outbound HTTPS Long-Poll     +-------------------------------+ |
|  |   Runner ScaleSet         | -------------------------------> |    GitHub Actions Backend     | |
|  |   Listener Pod            | <------------------------------- | (api.github.com / Broker)     | |
|  +---------------------------+       Job Available Event        +-------------------------------+ |
|                |                                                                |                 |
|       Demands New Replica                                              Issues Single-Use          |
|                v                                                           JIT Token              |
|  +---------------------------+       Schedules Runner Pod                       |                 |
|  |  ARC Controller Manager   | ----------------------------------+              |                 |
|  +---------------------------+                                   |              v                 |
|                                                                  v  +---------------------------+ |
|                                                                     | Ephemeral Runner Pod      | |
|  +---------------------------+     Scrapes :8080                    | - DinD Container          | |
|  |    Prometheus Server      | -----------------------------------> | - Runs 1 Job -> Self-Dest | |
|  +---------------------------+                                      +---------------------------+ |
+---------------------------------------------------------------------------------------------------+
```

- **Ephemeral Pods:** Each runner executes exactly one job and terminates. Zero leftovers, zero credential persistence.
- **Outbound Only:** No inbound ports, public IPs, or firewall openings needed in AKS.
- **Zero Idle Compute:** Scales down to `minRunners: 0` when the job queue is empty.

---

## 2. Prerequisites & Scope Setup

### 2.1 Azure Tools & Providers
Ensure Azure CLI and Terraform are installed:
```bash
az login
az account set --subscription "<Your-Subscription-ID>"

# Ensure required resource providers are registered
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
```

### 2.2 GitHub Token Setup
You must use a **Personal Access Token (Classic)**:
1. Navigate to **GitHub $\rightarrow$ Settings $\rightarrow$ Developer settings $\rightarrow$ Personal access tokens $\rightarrow$ Tokens (classic)**.
2. Select scopes:
   - For repository runner: `repo` (Full control of private repositories).
   - For organization runner: `admin:org`.
3. Export it in your active terminal:
```bash
export GITHUB_TOKEN="ghp_YourActualTokenHere"
```

---

## 3. All Production Configuration Files

### Terraform: Provider & Versions (`versions.tf`)
```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116" # Pinned to 3.x to avoid v4 breaking schema requirements
    }
  }
}

provider "azurerm" {
  features {}
}
```

### Terraform: Main AKS Cluster Infrastructure (`main.tf`)
```hcl
locals {
  resource_group_name = "rg-arc-runners-${var.environment}"
}

resource "azurerm_resource_group" "rg" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "arcrunners-${var.environment}"

  default_node_pool {
    name                = "default"
    node_count          = 2
    vm_size             = "Standard_DS2_v2"
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 5
  }

  identity {
    type = "SystemAssigned"
  }
}
```

### Terraform: Input Variables (`variables.tf`)
```hcl
variable "location" {
  type        = string
  description = "Azure region for deployment"
  default     = "eastus"
}

variable "cluster_name" {
  type        = string
  description = "AKS Cluster name"
  default     = "arc-runner-cluster"
}

variable "environment" {
  type        = string
  description = "Deployment environment name"
  default     = "dev"
}
```

### Terraform: Outputs (`outputs.tf`)
```hcl
output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}
```

---

### Helm Values: ARC Scale Set (`arc-values.yaml`)
> **CRITICAL:** Notice that every metric under `counters` and `gauges` must have `labels: []` declared. Do not put your token in this file.

```yaml
## Helm values for gha-runner-scale-set
githubConfigUrl: "https://github.com/AsadulCloud/azure-devops-portfolio"

minRunners: 0
maxRunners: 10
runnerScaleSetName: "aks-autoscaler-fleet"

containerMode:
  type: "dind"

# Listener metrics configuration matching ARC CRD v1alpha1
listenerMetrics:
  counters:
    gha_started_jobs_total:
      labels: []
    gha_completed_jobs_total:
      labels: []
  gauges:
    gha_running_jobs:
      labels: []
    gha_registered_runners:
      labels: []
    gha_busy_runners:
      labels: []
    gha_idle_runners:
      labels: []
    gha_desired_runners:
      labels: []
    gha_max_runners:
      labels: []
    gha_min_runners:
      labels: []
```

---

### Kubernetes: Metrics Services (`metrics-services.yaml`)
Services allow Prometheus to reliably discover and scrape port 8080 on both the ARC Controller and the ARC Listener.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: arc-metrics
  namespace: arc-systems
  labels:
    app.kubernetes.io/name: gha-rs-controller
spec:
  selector:
    app.kubernetes.io/name: gha-rs-controller
  ports:
    - name: metrics
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: arc-listener-metrics
  namespace: arc-systems
  labels:
    app.kubernetes.io/name: aks-autoscaler-fleet
spec:
  selector:
    app.kubernetes.io/name: aks-autoscaler-fleet
  ports:
    - name: metrics
      port: 8080
      targetPort: 8080
```

---

### Helm Values: Prometheus Scrape Config (`prometheus-extra-scrape.yaml`)
> **CRITICAL:** `extraScrapeConfigs` must be a multiline string scalar (`|`), not a parsed YAML array.

```yaml
extraScrapeConfigs: |
  - job_name: 'arc-controller'
    scrape_interval: 15s
    metrics_path: /metrics
    static_configs:
      - targets: ['arc-metrics.arc-systems.svc.cluster.local:8080']
  - job_name: 'arc-listener'
    scrape_interval: 15s
    metrics_path: /metrics
    static_configs:
      - targets: ['arc-listener-metrics.arc-systems.svc.cluster.local:8080']
```

---

### GitHub Actions: Multi-Pod Stress Workflow (`.github/workflows/arc-test.yml`)
Place this inside your repository at `.github/workflows/arc-test.yml`:

```yaml
name: Test ARC Multi-Pod Autoscaling

on:
  workflow_dispatch:

jobs:
  parallel-stress-test:
    runs-on: aks-autoscaler-fleet
    strategy:
      fail-fast: false
      matrix:
        worker: [1, 2, 3, 4, 5, 6, 7, 8]
    steps:
      - name: Report Runner Instance
        run: |
          echo "Starting Worker ${{ matrix.worker }} on AKS!"
          hostname
          uname -a

      - name: Simulate Build Workload
        run: |
          echo "Worker ${{ matrix.worker }} holding runner active for 45 seconds..."
          sleep 45
```

---

## 4. Step-by-Step Deployment Runbook

### Phase 1: Deploy AKS Cluster with Terraform
```bash
terraform init
terraform plan -out=aks_runner.plan
terraform apply aks_runner.plan

# Connect kubectl to AKS
az aks get-credentials --resource-group rg-arc-runners-dev --name arc-runner-cluster
```

### Phase 2: Deploy ARC Controller Manager
Deploy the controller with `--metrics-addr` set to `:8080` (enabling metrics output):
```bash
helm install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace arc-systems \
  --create-namespace \
  --set metrics.controllerManagerAddr=":8080" \
  --set metrics.listenerAddr=":8080" \
  --set metrics.listenerEndpoint="/metrics"
```

### Phase 3: Deploy ARC Runner ScaleSet
Inject the GitHub Token safely via `--set` without exposing it in plaintext:
```bash
helm install my-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace arc-runners \
  --create-namespace \
  -f arc-values.yaml \
  --set githubConfigSecret.github_token="$GITHUB_TOKEN"
```

### Phase 4: Apply Metrics Services
```bash
kubectl apply -f metrics-services.yaml
```

### Phase 5: Deploy Prometheus with Scrape Jobs
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  -f prometheus-extra-scrape.yaml
```

---

## 5. Every Issue Encountered, Why It Happened & The Fix

### Issue 1: `SubscriptionNotFound` & Provider `NotRegistered`
- **Error:** `(SubscriptionNotFound) Subscription 3f29debf-... was not found` and `Microsoft.Storage NotRegistered`.
- **Why it happened:** Azure CLI held an expired cached context from a previous lab/subscription, and new subscriptions do not register resource providers automatically.
- **The Fix:**
  ```bash
  az account list --output table
  az account set --subscription "<Valid-Subscription-ID>"
  az provider register --namespace Microsoft.Storage
  az provider register --namespace Microsoft.ContainerService
  ```

---

### Issue 2: `Error acquiring the state lock`
- **Error:** `state blob is already locked. Lock Info ID: 3df9d23a-e164-9178-c049-adb5037d32b0`.
- **Why it happened:** A previous Terraform plan/apply process was aborted before releasing the lease lock on the Azure Blob Storage state container.
- **The Fix:**
  ```bash
  terraform force-unlock 3df9d23a-e164-9178-c049-adb5037d32b0
  ```

---

### Issue 3: Terraform Literal Variable Quote Error
- **Error:** AKS cluster named literally `"var.cluster_name"`.
- **Why it happened:** Double quotes (`name = "var.cluster_name"`) treat the expression as a raw string literal instead of reading the variable reference.
- **The Fix:**
  ```hcl
  # WRONG:  name = "var.cluster_name"
  # RIGHT:  name = var.cluster_name
  ```

---

### Issue 4: `Error: Insufficient node_provisioning_profile blocks`
- **Error:** Terraform validate failed demanding `node_provisioning_profile`.
- **Why it happened:** `azurerm` v4+ introduced breaking schema changes requiring Node Autoprovisioning definitions.
- **The Fix:** Pin provider version to `~> 3.116` in `versions.tf` to maintain compatibility with standard AKS clusters.

---

### Issue 5: Bash Backslash Syntax Failure during Helm Install
- **Error:** `unexpected arguments: arc-systems... No such file or directory`.
- **Why it happened:** Trailing spaces after `\` or placing ` \ --namespace` caused Bash to terminate line continuation and evaluate arguments as broken shell commands.
- **The Fix:** Format commands cleanly on a single line or ensure `\` is the very last character on the line with zero trailing spaces.

---

### Issue 6: Helm Token Ingestion Failure
- **Error:** `A valid .Values.githubConfigSecret is required...`
- **Why it happened:** `$GITHUB_TOKEN` was unset in a new terminal window, evaluating to an empty string `""`.
- **The Fix:** Re-run `export GITHUB_TOKEN="ghp_xxx"` in the active terminal window before running Helm.

---

### Issue 7: ARC Metric Schema Type Mismatch
- **Errors:**
  1. `.spec.listenerMetrics.counters: expected map, got &{[gha_started_jobs_total...]}`
  2. `.spec.listenerMetrics.counters.gha_completed_jobs_total.name: field not declared in schema`
  3. `spec.listenerMetrics.counters.gha_completed_jobs_total.labels: Required value`
- **Why it happened:** ARC's Custom Resource Definition expects each metric to be a map key whose value is an object containing a required `labels` list.
- **The Fix:** Configure every counter and gauge under `listenerMetrics` as:
  ```yaml
  listenerMetrics:
    counters:
      gha_completed_jobs_total:
        labels: []
  ```

---

### Issue 8: Metrics Server Disabled in ARC Controller
- **Inspection Output:** `args: ["--metrics-addr=0", "--listener-metrics-addr=0"]`
- **Why it happened:** The controller defaults to disabling its internal metrics server by binding to port `0`.
- **The Fix:** Upgrade the controller Helm chart passing `--set metrics.controllerManagerAddr=":8080"` and `--set metrics.listenerAddr=":8080"`.

---

### Issue 9: Prometheus Helm Schema Error (`got array, want string`)
- **Error:** `at '/extraScrapeConfigs': got array, want string`.
- **Why it happened:** Passing JSON arrays via `--set-json` violates the Prometheus chart schema, which expects a raw multiline YAML string block.
- **The Fix:** Save the scrape configuration using YAML scalar syntax (`extraScrapeConfigs: |`) in `prometheus-extra-scrape.yaml` and pass via `-f`.

---

### Issue 10: Prometheus Server Not Reloading Configuration
- **Symptom:** `prometheus-server` remained at an age of `124m` and did not scrape the new targets.
- **Why it happened:** Helm ConfigMap updates do not trigger an immediate restart of standard Kubernetes deployments.
- **The Fix:**
  ```bash
  kubectl rollout restart deployment/prometheus-server -n monitoring
  ```

---

## 6. Telemetry & Verification Guide

### 6.1 Expose Prometheus Dashboard
```bash
kubectl port-forward svc/prometheus-server -n monitoring 9090:80
```
Open `http://127.0.0.1:9090` in your web browser.

### 6.2 Key PromQL Queries & Targets
- **Target Health:** Check `http://127.0.0.1:9090/targets`. Confirm both `arc-controller` and `arc-listener` show green **UP (1/1)** status.
- **Listener Pod Health:**
  ```promql
  gha_controller_running_listeners
  ```
  *Baseline value: `1.00`*
- **Real-Time Running Jobs (Scaling Spike):**
  ```promql
  sum(gha_running_jobs)
  ```
  *Visualizes real-time pod concurrency (e.g., spikes to 8.00 during stress tests and drops to 0.00 upon completion).*
- **Cumulative Completed Jobs:**
  ```promql
  sum(gha_completed_jobs_total)
  ```
  *Monotonic counter recording total successful CI/CD executions across your fleet.*

---

## 7. Teardown & Clean Up (Stop Azure Billing)

Always perform clean teardowns in this exact sequence to prevent orphaned cloud resources or Helm release locks:

```bash
# 1. Uninstall Helm Releases
helm uninstall my-runners -n arc-runners
helm uninstall arc -n arc-systems
helm uninstall prometheus -n monitoring

# 2. Delete Metrics Services
kubectl delete svc arc-metrics -n arc-systems --ignore-not-found
kubectl delete svc arc-listener-metrics -n arc-systems --ignore-not-found

# 3. Destroy AKS and Azure Resources
terraform destroy -auto-approve

# 4. Confirm Deletion in Azure
az group list -o table
```