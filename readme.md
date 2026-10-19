# Auto-Scaling GitHub Actions Runners on AKS (ARC)

[![Azure](https://img.shields.io/badge/Cloud-Azure%20AKS-0078D4?logo=microsoftazure)](https://azure.microsoft.com/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Orchestration-Kubernetes-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![Helm](https://img.shields.io/badge/Packaging-Helm-0F1689?logo=helm)](https://helm.sh/)
[![Prometheus](https://img.shields.io/badge/Monitoring-Prometheus-E6522C?logo=prometheus)](https://prometheus.io/)

A reference implementation of self-hosted GitHub Actions runners on Azure Kubernetes Service (AKS), using Actions Runner Controller (ARC). Runners are created on demand, run one job each, and scale back to zero when idle.

**Result:** In a load test, the fleet scaled from 0 to 8 ephemeral runner pods, completed all jobs, and returned to 0 within about 90 seconds.

---

## Table of Contents

1. [Problem](#problem)
2. [Solution](#solution)
3. [Architecture](#architecture)
4. [Load Test Results](#load-test-results)
5. [Repository Layout](#repository-layout)
6. [Prerequisites](#prerequisites)
7. [Deployment](#deployment)
8. [Using the Runners](#using-the-runners)
9. [Monitoring](#monitoring)
10. [Limitations and Trade-offs](#limitations-and-trade-offs)
11. [Teardown](#teardown)
12. [Author](#author)

---

## Problem

Static self-hosted runner VMs have three common drawbacks:

- **Queues:** Concurrency is capped by the number of VMs. When several jobs start at once, the extra jobs wait for a free runner.
- **Idle cost:** To avoid queues, teams over-provision VMs and pay for them 24/7, including nights and weekends.
- **State leakage:** Persistent VMs reuse disks between jobs, which can leave behind credentials, artifacts, and configuration drift.

---

## Solution

This project runs ARC on AKS so that runners behave like short-lived, disposable workers:

| Feature | How it works |
|---|---|
| **Ephemeral runners** | Each runner pod gets a single-use Just-in-Time (JIT) token, runs exactly one job, then terminates. |
| **Scale to zero** | `minRunners: 0` and `maxRunners: 10`. No jobs queued means no runner pods. |
| **No inbound access** | The ARC listener pod opens an outbound HTTPS long-poll connection to GitHub. No public IP, ingress controller, or inbound firewall rule is needed. |
| **Container builds** | A Docker-in-Docker (DinD) sidecar lets workflows build images inside the cluster. |
| **Observability** | Prometheus scrapes ARC metrics across namespaces: running jobs, completed jobs, listener health, and runner utilization. |
| **Infrastructure as Code** | Terraform provisions the AKS cluster and node pools, with remote state in Azure Blob Storage. |

---

## Architecture

```text
           +-----------------------------+
           |   Developer Push / PR / CI  |
           +-----------------------------+
                          |
                          v
           +-----------------------------+
           |   GitHub Actions Job Queue  |
           +-----------------------------+
                          ^
    Outbound HTTPS        |  Job available signal
      long-poll           v
+-------------------------------------------------------------+
| Azure Kubernetes Service (AKS) cluster                      |
|                                                             |
|   +-----------------------------+                           |
|   | ARC Listener Pod            |                           |
|   | (namespace: arc-systems)    |                           |
|   +-----------------------------+                           |
|                  | desired replicas                         |
|                  v                                          |
|   +-----------------------------+                           |
|   | ARC Controller Manager      |                           |
|   | (namespace: arc-systems)    |                           |
|   +-----------------------------+                           |
|                  | creates ephemeral pods                   |
|                  v                                          |
|   +-----------------------------------------------------+   |
|   | namespace: arc-runners                              |   |
|   |  [Runner Pod 1] [Runner Pod 2] ... [Runner Pod N]   |   |
|   |   one job each, then terminated                     |   |
|   +-----------------------------------------------------+   |
|                                                             |
|   +-----------------------------+                           |
|   | Prometheus                  |  scrapes ARC metrics      |
|   | (namespace: monitoring)     |  on port 8080             |
|   +-----------------------------+                           |
+-------------------------------------------------------------+
```

**Flow:** A workflow is triggered, the job queues in GitHub, the listener detects it and reports demand, the controller creates runner pods, each pod runs one job and is deleted, and the fleet returns to zero.

---

## Load Test Results

A GitHub Actions matrix workflow (`.github/workflows/arc-test.yml`) dispatched parallel jobs. The fleet scaled out to 8 concurrent runner pods, finished all jobs, and scaled back to zero.

![Runner concurrency spike](docs/assets/prometheus-running-jobs.png)
*Figure 1: `sum(gha_running_jobs)` rising to 8 during the test and returning to 0.*

![Completed jobs counter](docs/assets/prometheus-completed-jobs.png)
*Figure 2: `sum(gha_completed_jobs_total)` counting completed jobs.*

---

## Repository Layout

```text
aks-arc-autoscaling-runners/
├── .github/workflows/
│   └── arc-test.yml                  # Load-test matrix workflow
├── terraform/
│   ├── backend.tf                    # Remote state in Azure Blob Storage
│   ├── local.tf                      # Naming and tags
│   ├── main.tf                       # Resource group, AKS cluster, node pools
│   ├── variables.tf                  # Input variables
│   ├── output.tf                     # Cluster outputs
│   └── terraform.tfvars.example      # Example variables (no secrets)
├── helm/
│   └── arc-values.yaml               # Runner scale set values (min/max, DinD, metrics)
├── monitoring/
│   ├── metrics-services.yaml         # ClusterIP services exposing ARC metrics
│   └── prometheus-extra-scrape.yaml  # Cross-namespace scrape config
├── docs/
│   ├── assets/                       # Screenshots and diagrams
│   └── troubleshooting-playbook.md   # Errors and fixes encountered
├── .gitignore
└── README.md
```

---

## Prerequisites

* **Azure CLI** (`az`), signed in with the `Contributor` role on the target subscription
* **Terraform** `>= 1.5.0`
* **kubectl** and **Helm** `>= 3.8.0`
* **GitHub Personal Access Token (classic)** with the `repo` scope (repository runners) or `admin:org` (organization runners)
* An Azure Storage account and container for Terraform remote state (configured in `terraform/backend.tf`)

---

## Deployment

### 1. Provision AKS with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit values as needed

terraform init
terraform plan -out=aks_runner.plan
terraform apply aks_runner.plan

az aks get-credentials --resource-group rg-arc-runners --name arc-runner-cluster
```

### 2. Install the ARC controller

```bash
# Keep the token in your shell session only. Never commit it.
export GITHUB_TOKEN="<your-github-pat>"

helm install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace arc-systems \
  --create-namespace \
  --set metrics.controllerManagerAddr=":8080"
```

### 3. Install the runner scale set

Before running this, make sure `githubConfigUrl` in `helm/arc-values.yaml` points to your repository or organization.

```bash
helm install my-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace arc-runners \
  --create-namespace \
  -f ../helm/arc-values.yaml \
  --set githubConfigSecret.github_token="$GITHUB_TOKEN"
```

### 4. Set up Prometheus

```bash
kubectl apply -f ../monitoring/metrics-services.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  -f ../monitoring/prometheus-extra-scrape.yaml

kubectl port-forward svc/prometheus-server -n monitoring 9090:80
```

Open `http://localhost:9090` to query metrics.

---

## Using the Runners

Set `runs-on` to the scale set name defined in `helm/arc-values.yaml` (`aks-autoscaler-fleet`):

```yaml
name: CI

on:
  push:
    branches: [ "main" ]

jobs:
  build:
    runs-on: aks-autoscaler-fleet
    steps:
      - uses: actions/checkout@v4
      - name: Confirm ephemeral runner
        run: |
          echo "Running on pod: $(hostname)"
          docker --version
```

---

## Monitoring

| Query | Meaning |
| --- | --- |
| `sum(gha_running_jobs)` | Jobs currently executing. Rises under load, returns to 0 when idle. |
| `sum(gha_completed_jobs_total)` | Total completed jobs (monotonic counter). |
| `gha_controller_running_listeners` | `1` means the listener is connected to GitHub. |
| `sum(gha_busy_runners) / sum(gha_registered_runners) * 100` | Runner utilization (%). |

---

## Limitations and Trade-offs

This is a lab-scale reference implementation, not a hardened production platform. Known limits:

* **Cold starts:** Scaling from zero adds latency (pod scheduling, image pull, and node scale-up if the cluster autoscaler must add a node). For latency-sensitive pipelines, set `minRunners` to 1 or 2.
* **Queueing still happens** when demand exceeds `maxRunners` (10). Raise the cap or add node capacity to handle larger bursts.
* **Authentication:** This setup uses a classic PAT for simplicity. For production, use a GitHub App, which has narrower permissions and is easier to rotate.
* **DinD security:** Docker-in-Docker mode runs a privileged container. Review this for your threat model, or consider rootless or Kaniko-style builds.
* **Cost savings are not measured:** Scale-to-zero removes idle runner compute, but this repo does not include a cost comparison against static VMs. The AKS control plane and any always-on system node pool still cost money.
* **Single cluster, single region:** No high-availability or multi-region design.

**Possible next steps:** GitHub App authentication, a Grafana dashboard, a measured cost comparison, and a node autoscaling test.

---

## Teardown

Remove everything to stop Azure charges:

```bash
helm uninstall my-runners -n arc-runners
helm uninstall arc -n arc-systems
helm uninstall prometheus -n monitoring

cd terraform
terraform destroy
```

---

## Author

**Md. Asadul Howlader**

* GitHub: [@AsadulCloud](https://github.com/AsadulCloud)
* LinkedIn: [Md. Asadul Howlader](https://www.linkedin.com/in/md-asadul-howlader-96aa821b9)
