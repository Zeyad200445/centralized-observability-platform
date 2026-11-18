# Centralized Observability Platform

A Kubernetes-native logging and metrics platform for Google Cloud, built the
"local first, cloud second" way: the entire Terraform and Ansible codebase is
exercised against the `floci-gcp` emulator on a laptop before a single
billable GCP resource is created, then promoted to real GKE by switching one
directory.

Any workload scheduled into the cluster has its logs shipped, Grok-parsed and
indexed into Elasticsearch automatically, and its node, cluster and cloud
metrics scraped into Prometheus and graphed in Grafana. No application code
changes are required.

---

## Table of contents

1. [What gets built](#1-what-gets-built)
2. [Prerequisites](#2-prerequisites)
3. [Local run, step by step](#3-local-run-step-by-step)
4. [Verifying both pipelines](#4-verifying-both-pipelines)
5. [Promotion to real GCP](#5-promotion-to-real-gcp)
6. [Repository layout](#6-repository-layout)
7. [Configuration reference](#7-configuration-reference)
8. [Troubleshooting](#8-troubleshooting)
9. [Teardown](#9-teardown)

---

## 1. What gets built

### Layer A - infrastructure (Terraform)

| Resource | Module | Notes |
|---|---|---|
| Custom VPC + regional subnet | `modules/vpc` | One primary CIDR for nodes, two secondary CIDRs for Pods and Services (VPC-native alias IPs) |
| Firewall rules | `modules/vpc` | Intra-cluster east-west, control-plane to webhooks, scoped admin access |
| GKE cluster | `modules/gke` | VPC-native, Workload Identity enabled, default node pool removed |
| Managed node pool | `modules/gke` | Dedicated node service account, `cloud-platform` scope |
| `obs-gke-node-sa` | `modules/iam` | Telemetry **writer** roles only |
| `obs-gcp-exporter-sa` | `modules/iam` | `roles/monitoring.viewer` only |
| Workload Identity binding | `modules/iam` | `roles/iam.workloadIdentityUser` for `monitoring/gcp-exporter-sa` |

### Layer B - configuration (Ansible + Jinja2 + Helm)

Three isolated namespaces, Kubernetes Secrets rendered from Jinja2, a
ClusterRole and ClusterRoleBinding granting `get`/`list`/`watch` on nodes,
pods, services and endpoints to the Prometheus and Filebeat service accounts,
and four Helm releases plus one set of raw manifests.

### Layer C - logging pipeline (`logging` namespace)

```
nginx pod stdout
  -> containerd writes /var/log/pods/**.log  (symlinked from /var/log/containers)
     -> Filebeat DaemonSet  (hostPath read-only, adds Kubernetes metadata)
        -> Logstash :5044   (beats input -> grok filter -> elasticsearch output)
           -> Elasticsearch :9200  (StatefulSet + PVC, index logstash-k8s-YYYY.MM.dd)
              -> Kibana :5601
```

Grok turns one opaque line into `timestamp`, `client_ip`, `http_method`,
`request_path`, `http_status`, `bytes_sent`, `log_level` and `raw_message`.

### Layer D - metrics pipeline (`monitoring` namespace)

```
node /proc,/sys  -> Node Exporter DaemonSet :9100         --.
Kubernetes API   -> Kube State Metrics Deployment :8080   --+-> Prometheus :9090 -> Grafana :3000
Cloud Monitoring -> GCP Stackdriver Exporter :9255        --'   (StatefulSet + PVC, 15s scrape)
```

---

## 2. Prerequisites

| Tool | Minimum | Check |
|---|---|---|
| Docker Engine + Compose v2 | 24.0 | `docker compose version` |
| Terraform | 1.6.0 | `terraform version` |
| kubectl | 1.28 | `kubectl version --client` |
| Helm | 3.12 | `helm version` |
| Ansible | 2.15 (core) | `ansible --version` |
| Python | 3.9 | `python3 --version` |
| `make`, `curl`, `jq` | any | `make -v` |

Python libraries the `kubernetes.core` collection imports:

```bash
pip install "kubernetes>=28.1.0" "PyYAML>=6.0" "jsonpatch>=1.33"
```

Ansible collections (the Makefile does this for you, but you can run it early):

```bash
ansible-galaxy install -r ansible/requirements.yml
```

Your Docker daemon needs roughly **8 GB of RAM and 4 CPUs** available.
Elasticsearch, Prometheus, Grafana, Kibana and Logstash inside one k3s
container is not a light footprint.

---

## 3. Local run, step by step

### 3.1 Clone and enter

```bash
git clone <your-fork-url> centralized-observability-platform
cd centralized-observability-platform
```

### 3.2 Start the emulator

```bash
make up
```

This runs `docker compose up -d` and then blocks on
`scripts/wait-for-emulator.sh`, which polls
`http://localhost:4588/_floci-gcp/health` **and verifies that
`/var/run/docker.sock` is actually mounted into the container**. That second
check matters: GKE is a Docker-backed service in floci-gcp. Without the
socket, cluster creation degrades to a mock object with no reachable API
server and everything downstream fails in a confusing way.

Verify by hand if you like:

```bash
curl -s http://localhost:4588/_floci-gcp/health
curl -s http://localhost:4588/_floci-gcp/info
docker compose ps
```

### 3.3 Provision the infrastructure

```bash
make local-apply
```

Equivalent to:

```bash
export GOOGLE_OAUTH_ACCESS_TOKEN=floci-mock-access-token
terraform -chdir=terraform/environments/local init
terraform -chdir=terraform/environments/local apply -auto-approve -parallelism=1
```

**`-parallelism=1` is not optional.** Both the emulator's IAM policy store
and real GCP's `google_project_iam_member` do read-modify-write against a
single project policy document. Concurrent writes drop bindings silently, and
you find out weeks later when the exporter cannot read metrics.

While this runs, watch the emulator start a real k3s container:

```bash
docker ps --filter "name=obs-"
docker logs -f floci-gcp
```

Inspect what was created:

```bash
make local-output
terraform -chdir=terraform/environments/local state list
```

### 3.4 Generate the kubeconfig

```bash
make kubeconfig
```

Writes `terraform output -raw kubeconfig` to `.floci/kubeconfig`, chmods it to
`600` and immediately runs `kubectl get nodes` against it. You should see one
`Ready` node.

```bash
export KUBECONFIG=$PWD/.floci/kubeconfig
kubectl get nodes -o wide
kubectl cluster-info
```

### 3.5 Deploy the observability stacks

```bash
make deploy
```

Equivalent to:

```bash
ansible-galaxy install -r ansible/requirements.yml
KUBECONFIG=$PWD/.floci/kubeconfig ansible-playbook \
  -i ansible/inventory/hosts.ini \
  ansible/playbook.yml \
  -e kubeconfig_path=$PWD/.floci/kubeconfig
```

The playbook creates the three namespaces, the Secrets, the RBAC, then
installs Elasticsearch, Logstash, Kibana, Filebeat, kube-prometheus-stack and
the GCP exporter. First run takes 10-20 minutes, almost all of it pulling
images.

Deploy one half only:

```bash
make deploy-logging      # --tags logging
make deploy-monitoring   # --tags monitoring
make check               # --check --diff, changes nothing
```

Inspect exactly what Helm received - the rendered Jinja2 output is written to
disk before being applied:

```bash
cat ansible/rendered/elk-values.yml
cat ansible/rendered/monitoring-values.yml
cat ansible/rendered/gcp-exporter.yml
```

### 3.6 Deploy the test workload

```bash
make workload
```

Starts `nginx-demo` (2 replicas, with a Prometheus exporter sidecar), a
`load-generator` producing a steady 200/404/500 mix, and an `app-logger`
emitting levelled application logs including a multi-line stack trace.

### 3.7 Full bring-up in one command

```bash
make all
```

Runs `up -> local-apply -> kubeconfig -> deploy -> workload -> smoke`.

---

## 4. Verifying both pipelines

### 4.1 Automated

```bash
make smoke
```

`scripts/smoke-test.sh` checks the emulator health endpoint and the socket
mount, that nodes are `Ready`, that every pod in `logging`, `monitoring` and
`workload` is `Running` with all containers ready, drives real HTTP 200 and
404 requests through nginx, waits for propagation, then queries Elasticsearch
for documents with parsed `http_status`, `client_ip` and `request_path`
fields, and finally asks Prometheus whether the three exporters are `UP`.

Exit code `0` means both pipelines are live end to end.

### 4.2 By hand - logging

```bash
export KUBECONFIG=$PWD/.floci/kubeconfig

# Elasticsearch
kubectl -n logging port-forward svc/elasticsearch-master 9200:9200 &
ES_PW=$(kubectl -n logging get secret elastic-credentials -o jsonpath='{.data.password}' | base64 -d)

curl -s -u elastic:$ES_PW 'http://localhost:9200/_cat/indices?v'
curl -s -u elastic:$ES_PW 'http://localhost:9200/_cluster/health?pretty'

# Prove Grok actually split the line into fields
curl -s -u elastic:$ES_PW -H 'Content-Type: application/json' \
  -XPOST 'http://localhost:9200/logstash-k8s-*/_search?pretty&size=2' -d '{
    "query": { "bool": { "filter": [
      { "term": { "http_status": 404 } },
      { "exists": { "field": "client_ip" } }
    ]}}
  }'

# Count by status code
curl -s -u elastic:$ES_PW -H 'Content-Type: application/json' \
  -XPOST 'http://localhost:9200/logstash-k8s-*/_search?pretty&size=0' -d '{
    "aggs": { "by_status": { "terms": { "field": "http_status" } } }
  }'
```

Kibana:

```bash
make kibana            # port-forward to http://localhost:5601
```

Log in as `elastic` with the password above. Create a data view for
`logstash-k8s-*` with time field `@timestamp`, then query in KQL:

```
http_status >= 400 and kubernetes.namespace : "workload"
log_level : "ERROR"
request_path : "/generate-404"
```

### 4.3 By hand - metrics

```bash
make prometheus        # http://localhost:9090
```

```bash
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq -r \
  '.data.activeTargets[] | "\(.labels.job)\t\(.health)"' | sort -u
```

Useful queries:

```promql
up
rate(node_cpu_seconds_total{mode!="idle"}[5m])
kube_pod_status_phase{namespace="workload"}
sum by (pod) (kube_pod_container_status_restarts_total{namespace="workload"})
nginx_http_requests_total
stackdriver_gce_instance_compute_googleapis_com_instance_cpu_utilization
```

Grafana:

```bash
make grafana           # http://localhost:3000
kubectl -n monitoring get secret grafana-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Log in as `admin`. The Prometheus data source is already the default, an
Elasticsearch data source pointing at `logstash-k8s-*` is also provisioned,
and the Kubernetes/Node dashboards are pre-loaded under the **Observability**
folder.

---

## 5. Promotion to real GCP

Nothing about the module graph changes. `environments/gcp/main.tf` calls the
same `../../stack` module with the same argument names; only the provider
endpoints, the backend and the sizing differ.

### 5.1 Authenticate

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project MY-PROJECT-ID
```

In CI, use Workload Identity Federation rather than a downloaded key file.

### 5.2 Create the state bucket (once, out of band)

A backend cannot create the bucket it stores state in:

```bash
export TF_PROJECT=MY-PROJECT-ID
export TF_REGION=us-central1
export TF_BUCKET=obs-tfstate-$TF_PROJECT

gsutil mb -p $TF_PROJECT -l $TF_REGION gs://$TF_BUCKET
gsutil versioning set on gs://$TF_BUCKET
```

GCS backend locking is automatic - it writes a `.tflock` object and relies on
object generation preconditions. There is no DynamoDB equivalent to set up.

### 5.3 Fill in the variables

```bash
cd terraform/environments/gcp
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # at minimum: project_id
```

### 5.4 Initialise against the remote backend

```bash
terraform init \
  -backend-config="bucket=$TF_BUCKET" \
  -backend-config="prefix=observability/gcp"
```

### 5.5 Plan, then apply

```bash
make gcp-plan
make gcp-apply
```

Budget 15-25 minutes: GKE cluster creation dominates.

### 5.6 Get credentials and deploy the same playbook

```bash
make gcp-kubeconfig
```

which expands to:

```bash
gcloud container clusters get-credentials \
  $(terraform -chdir=terraform/environments/gcp output -raw cluster_name) \
  --region $(terraform -chdir=terraform/environments/gcp output -raw region) \
  --project $(terraform -chdir=terraform/environments/gcp output -raw project_id)
```

Then run the **same** playbook, pointing it at the cloud Terraform state so it
picks up the real exporter service account email:

```bash
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbook.yml \
  -e kubeconfig_path=$HOME/.kube/config \
  -e is_emulated=false \
  -e terraform_env_dir=$PWD/terraform/environments/gcp \
  -e storage_class=standard-rwo
```

Setting `is_emulated=false` flips every environment-dependent default at once:
three Elasticsearch replicas instead of one, hard anti-affinity, TLS between
ELK components, real Workload Identity annotations on the exporter service
account, Alertmanager enabled, longer retention and larger volumes.

Deploy the workload and verify:

```bash
kubectl apply -f workloads/test-app.yaml
SKIP_EMULATOR=1 ./scripts/smoke-test.sh
```

### 5.7 Confirm Workload Identity actually works

This is the one thing that cannot be rehearsed locally, so check it
explicitly:

```bash
kubectl -n monitoring get sa gcp-exporter-sa -o yaml | grep iam.gke.io

kubectl -n monitoring exec deploy/gcp-stackdriver-exporter -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
```

The second command must print `obs-gcp-exporter-sa@PROJECT.iam.gserviceaccount.com`.
If it prints the node service account instead, the annotation or the
`roles/iam.workloadIdentityUser` binding is wrong.

### 5.8 Expose the UIs

Port-forwarding is fine for a smoke test, not for daily use. For real access,
put Kibana and Grafana behind an Ingress with Google-managed certificates and
IAP, or behind your existing internal load balancer. Neither UI should be
reachable from the public internet with only a password in front of it.

---

## 6. Repository layout

```
centralized-observability-platform/
├── README.md                      this file
├── Makefile                       every workflow, local and cloud
├── docker-compose.yml             floci-gcp emulator + docker.sock mount
├── .gitignore                     state, kubeconfigs, secrets, rendered output
├── scripts/
│   ├── wait-for-emulator.sh       health gate + socket passthrough check
│   └── smoke-test.sh              end-to-end verification of both pipelines
├── terraform/
│   ├── modules/
│   │   ├── vpc/                   network, subnet, secondary ranges, firewall
│   │   ├── iam/                   two service accounts + Workload Identity
│   │   └── gke/                   cluster, node pool, kubeconfig output
│   ├── stack/                     the single composition root
│   └── environments/
│       ├── local/                 emulator endpoints, local state
│       └── gcp/                   ADC, GCS backend, tfvars example
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml           kubernetes.core, community.general, ansible.posix
│   ├── inventory/hosts.ini        localhost; the cluster is reached via API
│   ├── group_vars/all.yml         every tunable in one place
│   ├── playbook.yml               namespaces, secrets, RBAC, Helm, exporter
│   └── templates/
│       ├── elk-values.yml.j2      values for all four Elastic releases
│       ├── monitoring-values.yml.j2  kube-prometheus-stack values
│       └── gcp-exporter.yml.j2    exporter manifests + ServiceMonitor
└── workloads/
    └── test-app.yaml              nginx + exporter sidecar + load gen + logger
```

---

## 7. Configuration reference

Everything tunable lives in `ansible/group_vars/all.yml`. The highest-value
knobs:

| Variable | Default (local) | Meaning |
|---|---|---|
| `is_emulated` | `true` | Master switch. Flips replicas, storage class, TLS, anti-affinity, Workload Identity |
| `storage_class` | `local-path` | `standard-rwo` on GKE |
| `elastic_stack_version` | `8.5.1` | Elastic chart **and** image version |
| `kube_prometheus_stack_version` | `65.5.1` | Chart version, pinned deliberately |
| `prometheus_scrape_interval` | `15s` | Global scrape interval |
| `logstash_index_pattern` | `logstash-k8s` | Daily index becomes `logstash-k8s-YYYY.MM.dd` |
| `gcp_exporter_metric_prefixes` | 8 prefixes | **Main cost driver.** Each prefix is one Monitoring API call per scrape |
| `gcp_exporter_scrape_interval` | `5m` | Deliberately not 15s; see below |

### Why the GCP exporter scrapes every 5 minutes, not 15 seconds

Cloud Monitoring publishes most series at one-minute granularity at best, with
a three to four minute ingestion delay. Scraping every 15 seconds would
multiply the API bill without producing a single new data point. The 15-second
requirement applies to the in-cluster exporters, where it buys real
resolution.

### Secrets

The `vault_*` variables in `group_vars/all.yml` are development defaults.
Before sharing this repository:

```bash
ansible-vault encrypt_string 'YourRealPassword' --name 'vault_elastic_password'
```

Move the output into `ansible/group_vars/vault.yml` and run with
`--vault-password-file`. Nothing else needs to change: the playbook already
reads these through variables and writes them into Kubernetes Secrets with
`no_log: true`.

---

## 8. Troubleshooting

**`make up` fails the socket check**
The compose file must mount `/var/run/docker.sock`. On Docker Desktop, confirm
the socket path under Settings and that your user can reach it
(`docker ps` without `sudo`).

**Terraform: `Error: Provider produced inconsistent result`**
Almost always parallelism. Re-run with `-parallelism=1`. The Makefile targets
already do this; a hand-typed `terraform apply` will not.

**`kubectl` cannot reach the cluster after `make kubeconfig`**
Check the k3s container is actually up (`docker ps --filter name=obs-`) and
that port 6443 is published. `docker logs floci-gcp` shows the cluster-create
call and what it did with the Docker API.

**Elasticsearch pod in `CrashLoopBackOff` with `max virtual memory areas too low`**
`vm.max_map_count` is below 262144. The chart's `sysctlInitContainer` handles
this on GKE. On Docker Desktop, raise it on the host:
`sudo sysctl -w vm.max_map_count=262144`.

**Pods `Pending` with `Insufficient cpu` or `Insufficient memory`**
The whole stack does not fit in a small Docker VM. Give Docker at least 8 GB
and 4 CPUs, or reduce the resource requests in `group_vars/all.yml`.

**Elasticsearch has no `logstash-k8s-*` index**
Work backwards along the pipeline:

```bash
kubectl -n logging logs ds/filebeat --tail=50        # is it harvesting?
kubectl -n logging logs deploy/logstash --tail=50    # grok failures?
kubectl -n workload logs deploy/nginx-demo -c nginx  # is anything being logged?
```

A `_grokparsefailure` tag on documents means the access log format and the
Grok pattern have diverged. They are cross-referenced in `workloads/test-app.yaml`
and `ansible/templates/elk-values.yml.j2`; change both together.

**Prometheus shows the GCP exporter as `DOWN`**
Locally this is expected to carry no real data - floci-gcp emulates the
Monitoring API surface but holds no time series. On real GCP, check the
Workload Identity chain in section 5.7.

**`Failed to import the required Python library (kubernetes)`**
`pip install kubernetes` into the *same* interpreter Ansible uses:
`ansible --version` prints it on the `python version` line.

---

## 9. Teardown

Local:

```bash
make local-destroy     # terraform destroy -parallelism=1
make nuke              # stop the emulator, remove its state and k3s sidecars
# or both at once:
make clean
```

Cloud:

```bash
# deletion_protection defaults to true in terraform.tfvars.example;
# set it to false and apply before destroying.
make gcp-destroy
```

The GCS state bucket and anything in it are deliberately **not** destroyed by
Terraform. Remove it by hand when you are certain:

```bash
gsutil -m rm -r gs://$TF_BUCKET
```
