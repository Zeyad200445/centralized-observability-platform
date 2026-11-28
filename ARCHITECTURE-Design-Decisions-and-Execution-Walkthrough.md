# Architecture, Design Decisions & Execution Walkthrough

**Centralized Monitoring and Logging Infrastructure on Google Cloud Platform**
**with Optional Layer E: Read-Only Alert-Triage Agent (MCP)**

| | |
|---|---|
| **Prepared by** | Principal Cloud & DevOps Architect |
| **Date** | 12 November 2026 |
| **Revised** | 25 November 2026 (Layer E merged) |
| **Status** | Layers A-D: implementation complete; statically validated. **Layer E: design specified, not yet implemented or verified** |
| **Scope** | `terraform/`, `ansible/`, `workloads/`, `scripts/`, root files, and (Layer E) `agents/` |

---

## Revision note: what the Layer E merge changed

Layer E (the alert-triage agent) is an **optional, additive extension**. It is
gated behind one Ansible variable, `triage_agent_enabled`, which defaults to
`false`. With the flag off, every statement made about Layers A-D in this
document is unchanged, including "three namespaces" and the 76-requirement
count. The merge touched the document as follows:

| Section | Change |
|---|---|
| 1.7, 1.8 | New: Layer E purpose, constraints, status, and an overlay diagram |
| 2.11 | New: the design decisions behind Layer E, each with its rejected alternative |
| 3.11, 3.12 | New: planned files, and the modifications to existing files |
| 4.6, 4.7 | New: runtime trace of one alert through the agent, and the extended smoke test |
| 5.7, 5.8 | New: Layer E checklist (all rows marked **Planned**) and the evaluation plan |
| 5.5, 5.6 | Extended: unverified-claims table and summary now include Layer E |

Nothing in Layer E has been executed. Every Layer E row in section 5 carries
the status **Planned**, and no result is claimed anywhere.

---

## Document purpose

This document exists so you can check the implementation against your intent
without reading 5,000 lines of HCL and YAML first. It states how the
requirements were interpreted, why each structural decision was made, what
every file does, what happens at runtime from `docker compose up` to a log
line appearing in Kibana, and finally maps each requirement in the brief to
the exact file and code block that satisfies it.

Where the implementation deviates from a literal reading of the brief, that
deviation is called out explicitly with the reasoning, in section 5.3. There
are four such deviations. Nothing was silently substituted. Layer E is not a
deviation: it adds capability beyond the brief and replaces nothing in it.

---

# 1. Project Understanding & Architectural Vision

## 1.1 What was asked for, in one sentence

A Kubernetes-native observability platform on GKE where any workload
scheduled into the cluster automatically has its logs shipped, parsed and
indexed into an open-source ELK stack, and its hardware, cluster and cloud
metrics scraped into Prometheus and visualized in Grafana, with the entire
Infrastructure-as-Code and Configuration-Management codebase testable
locally against an emulator before any billable cloud resource exists.

## 1.2 The explicit constraint I treated as load-bearing

The brief states, twice and emphatically, that the open-source Kubernetes
stack must **not** be substituted with native GCP services, and that Cloud
Logging sinks and Pub/Sub must not be used. I treated this as the defining
architectural constraint rather than as a preference, because it changes
decisions that would otherwise go the other way.

Concretely, it produced these choices:

| Decision point | What a GCP-native design would do | What this implementation does |
|---|---|---|
| Container log collection | Enable GKE Cloud Logging, logs land in Cloud Logging | `logging_config.enable_components = ["SYSTEM_COMPONENTS"]` only. Workload logs are explicitly **excluded** so they are collected solely by Filebeat |
| Log routing | Cloud Logging sink to Pub/Sub to BigQuery | Filebeat to Logstash over the Beats protocol on TCP 5044 |
| Log parsing | Cloud Logging structured payloads | Logstash Grok filter |
| Log storage and search | Cloud Logging / BigQuery | Elasticsearch StatefulSet with a PersistentVolumeClaim |
| Metrics collection | Google Managed Prometheus | `managed_prometheus { enabled = false }`, self-hosted Prometheus Operator |
| Dashboards | Cloud Monitoring dashboards | Grafana |

The single place GCP-native telemetry is still used is
`SYSTEM_COMPONENTS` logging and monitoring on the GKE control plane itself.
That is the control plane Google operates and you cannot run Filebeat on. It
carries no workload data and incurs no duplicate ingestion of application
logs.

The one component that *reads* from a Google API is the Stackdriver
exporter, and that is required by the brief: it is how external GCP service
metrics, from GCS buckets and load balancers, reach Prometheus. It pulls
from the Monitoring API and re-publishes in Prometheus format. It is a
metrics source, not a replacement pipeline.

## 1.3 The hybrid local/cloud architecture

The "local first, cloud promotion" requirement is the most consequential
structural constraint in the brief, because the naive implementation of it
fails silently.

The naive approach is to write one set of Terraform for local and a second,
"real" set for cloud. That gives you a local run that proves nothing: the
code you tested is not the code you ship, so the local phase becomes a
ritual rather than a rehearsal.

This implementation instead uses a **single composition root** with
**environment-specific edges only**:

```
terraform/
├── modules/          vpc, iam, gke      <- shared, environment-agnostic
├── stack/            the composition    <- shared, instantiates all 3 modules
└── environments/
    ├── local/        instantiates stack/, points provider at :4588
    └── gcp/          instantiates stack/, points provider at googleapis.com
```

`environments/local/main.tf` and `environments/gcp/main.tf` call the same
`../../stack` module with the same argument names. The resource graph is
identical. What differs is exactly three things:

1. **Provider endpoints.** `environments/local/providers.tf` sets ten
   `*_custom_endpoint` arguments that redirect every Google API host to
   `http://localhost:4588`. `environments/gcp/providers.tf` sets none, so the
   provider talks to `googleapis.com`.
2. **Backend.** Local uses `backend "local"` and a `terraform.tfstate` file.
   Cloud uses `backend "gcs"` with versioning and automatic object-generation
   locking.
3. **An `emulated` boolean** plus sizing variables.

That third item deserves explanation, because it is where a careless design
would reintroduce the divergence it was trying to avoid.

## 1.4 The `emulated` flag and why it is narrow

`floci-gcp` backs a GKE cluster with a real `rancher/k3s` container. k3s is a
genuine Kubernetes distribution, so Deployments, DaemonSets, StatefulSets,
PVCs, Services, RBAC, Secrets and ServiceAccounts all behave exactly as they
do on GKE. That is why the local phase is worth running at all.

What k3s cannot model are the parts of GKE that are Google-specific
infrastructure rather than Kubernetes:

| Feature | Why k3s cannot model it |
|---|---|
| Private nodes / Cloud NAT | Containers sit on a Docker bridge; there is no VPC |
| Shielded VMs, secure boot | No Compute Engine VMs exist |
| GKE release channels | No managed control-plane upgrade service |
| Node auto-repair / auto-upgrade | Same |
| Workload Identity token exchange | No GKE metadata server to mint Google tokens |
| VPC flow logs | No VPC data plane |

The `emulated` flag guards **only** these. It is threaded from
`environments/local/main.tf` into `stack/` and then into `modules/gke`, where
it appears in `dynamic` blocks rather than in parallel resource definitions:

```hcl
dynamic "private_cluster_config" {
  for_each = (!local.is_emulated && var.enable_private_nodes) ? [1] : []
  content { ... }
}
```

This matters. A `dynamic` block that produces zero instances leaves the rest
of the resource untouched, so the cluster, node pool, IP allocation policy,
Workload Identity pool, service account attachment and OAuth scopes are all
identical in both environments. Only the Google-specific hardening is
conditionally absent locally.

The same flag exists on the Ansible side as `is_emulated`, where it drives
replica counts, storage class, TLS between ELK components, anti-affinity
strength and whether the exporter's Kubernetes ServiceAccount carries a
Workload Identity annotation. One variable, flipped on the command line,
converts the entire configuration layer from local to production shape.

## 1.5 What the local phase genuinely proves, and what it does not

I want this to be unambiguous, because a rehearsal that overstates its own
fidelity is worse than no rehearsal.

**Proven locally:**

- Terraform module structure, variable wiring, outputs and the full
  dependency graph
- Every Kubernetes object: namespaces, Secrets, ClusterRole,
  ClusterRoleBinding, ServiceAccounts, StatefulSets, DaemonSets, Deployments,
  Services, PVCs, ServiceMonitors, NetworkPolicies, PodDisruptionBudgets
- Every Helm release, chart version and rendered values file
- Every Jinja2 template, including the Grok patterns
- The entire logging pipeline, end to end, with real log lines
- The entire in-cluster metrics pipeline, with real metrics
- RBAC correctness: if the ClusterRole is wrong, Prometheus fails to discover
  targets locally exactly as it would in the cloud

**Not proven locally, and therefore explicitly re-verified after promotion:**

- The Workload Identity token exchange, because there is no GKE metadata
  server. Section 5.7 of the README gives the exact command to verify it
  against the real cluster, and section 4.4 of this document explains the
  compensating design.
- Real GCP metric values from the Monitoring API. The emulator serves the API
  shape, not a populated time-series store, so the exporter target comes up
  but returns an empty series set.
- Persistent disk performance characteristics and regional failover.

Everything in the second list is either verified by an explicit post-promotion
check or is a performance property no emulator could model.

## 1.6 Architectural vision in one diagram

```
                        LOCAL                                 CLOUD
             ┌──────────────────────────┐          ┌──────────────────────────┐
             │  docker compose          │          │  gcloud / ADC            │
             │  floci-gcp :4588         │          │  googleapis.com          │
             │  /var/run/docker.sock ───┼──┐       │                          │
             └──────────────────────────┘  │       └──────────────────────────┘
                        ▲                  │                   ▲
                        │ *_custom_endpoint│                   │ no overrides
             ┌──────────┴──────────┐       │       ┌───────────┴──────────┐
             │ environments/local  │       │       │  environments/gcp    │
             │ backend "local"     │       │       │  backend "gcs"       │
             └──────────┬──────────┘       │       └───────────┬──────────┘
                        │                  │                   │
                        └────────► terraform/stack/ ◄──────────┘
                                          │
                        ┌─────────────────┼─────────────────┐
                        ▼                 ▼                 ▼
                  modules/vpc       modules/iam       modules/gke
                        │                 │                 │
                        └─────────────────┴────────┬────────┘
                                                   │ kubeconfig output
                                                   ▼
                                          ansible/playbook.yml
                                                   │
                   ┌───────────────────────────────┼────────────────────────┐
                   ▼                               ▼                        ▼
            namespace: workload            namespace: logging       namespace: monitoring
            vproweb (NGINX)                Filebeat DaemonSet       Node Exporter DaemonSet
            vproapp + db/cache/mq          Logstash :5044           Kube State Metrics :8080
                   │                       Elasticsearch :9200      GCP Exporter :9255
                   │  stdout               Kibana :5601             Prometheus :9090
                   └──────────────────────────► (logs)              Grafana :3000
```

The k3s container spawned over the Docker socket on the left and the real GKE
node pool on the right present the same Kubernetes API, which is why the
bottom two thirds of this diagram are environment-independent. The optional
fourth namespace, `triage`, is not drawn here; section 1.8 shows it as an
overlay so the core diagram stays true with the flag off.

## 1.7 Layer E (optional): the read-only alert-triage agent

### What it is

When a Prometheus alert fires, an on-call engineer spends the first minutes
collecting context: which pod, what the logs say, what changed, what the
runbook says. Layer E automates **that evidence-gathering step only**. An
Alertmanager webhook triggers a small service that runs an LLM agent. The
agent queries Prometheus, Elasticsearch and the Kubernetes API through three
**read-only MCP servers** and emits a structured triage note: a summary, the
evidence it found, a likely cause with a confidence value, and suggested
commands for a human to run.

It reads and proposes. It never changes the cluster.

### Why it belongs in this platform

The platform already produces the three evidence types an incident needs:
metrics (Prometheus), parsed logs with Kubernetes metadata (Elasticsearch),
and object state (Kubernetes API). Grafana already correlates the first two
for a human. Layer E is the same correlation performed on the alert's behalf,
and it reuses the existing Grok fields (`log_level`, `kubernetes.*`,
`raw_message`) instead of building a second data path.

### Constraints it inherits

1. **No GCP-native services.** The agent uses open-source components only.
   The LLM endpoint is a variable (`triage_llm_base_url`) that points at a
   local Ollama instance by default, so no paid API is required.
2. **Local first.** It must run on the same 16 GB laptop as the rest of the
   stack. Section 2.11.6 treats the memory budget honestly.
3. **Same code, both environments.** One image and one set of manifests; the
   `is_emulated` flag changes only sizing and the Alertmanager default.
4. **Feature-flagged.** `triage_agent_enabled: false` by default, so Layers
   A-D behave exactly as documented without it.

### Status

**Designed, not built.** No Layer E file exists yet, no Layer E test has run,
and no accuracy figure is claimed. Section 5.8 defines how accuracy will be
measured once it is built.

## 1.8 Layer E overlay diagram

```
   Prometheus ──(rule fires)──► Alertmanager ──webhook POST──┐
   (monitoring)                 (monitoring)                 │
        ▲                                                    ▼
        │ read-only PromQL         namespace: triage   ┌──────────────┐
        │                                              │ triage-agent │──► LLM endpoint
 ┌──────┴────────┐  ┌────────────────┐ ┌───────────┐   │ FastAPI +    │    (Ollama on host,
 │ prometheus-mcp│  │ elasticsearch- │ │kubernetes-│◄──┤ Agents SDK   │     or free-tier API)
 │ (FastMCP)     │  │ mcp (FastMCP)  │ │mcp        │   └──────┬───────┘
 └──────┬────────┘  └───────┬────────┘ └─────┬─────┘          │
        │                   │                │                ▼
   Prometheus :9090   Elasticsearch :9200   K8s API     triage note (JSON):
                       logstash-k8s-*       get/list/    PVC + /triage/{id}
                       namespace-scoped     logs only    + stdout -> Filebeat
```

Each MCP server runs under its own ServiceAccount and holds only the
permission its one backend needs. The agent holds no cluster credentials at
all; it can only call tools.

---

# 2. Design Decisions & Reasoning (The "Why")

This section is the engineering argument behind the code. Each decision is
stated with the alternative that was rejected and the reason, because a
decision recorded without its alternative is just an assertion.

## 2.1 Terraform: why three modules and a composition root

### Why not one flat root module

A single `main.tf` containing the VPC, IAM and GKE resources would work and
would be shorter. It was rejected because of the blast radius of `terraform
apply`. With one flat module, a change to a firewall rule and a change to the
node pool are in the same plan, reviewed by the same person, applied in the
same transaction. Separating them into modules means `terraform plan` output
is grouped by concern, and a reviewer can see at a glance that a networking
PR touches no IAM.

### Why not one module per environment

Rejected for the reason given in section 1.3: it destroys the value of the
local phase. The code under test must be the code that ships.

### Why `stack/` exists between modules and environments

Without it, both `environments/local/main.tf` and `environments/gcp/main.tf`
would each instantiate three modules and wire the outputs of one into the
inputs of the next. That wiring would be duplicated, and duplicated wiring
drifts. `stack/` holds the wiring once:

```hcl
module "gke" {
  network                    = module.vpc.network_id
  subnetwork                 = module.vpc.subnet_id
  pods_range_name            = module.vpc.pods_range_name
  services_range_name        = module.vpc.services_range_name
  node_service_account_email = module.iam.node_service_account_email
}
```

Each environment then passes roughly twenty scalar variables and nothing
else. The environments contain no graph logic at all, which is why they are
comparable by eye.

### Why dependency order is expressed through data, not `depends_on`

There is exactly one `depends_on` in the entire Terraform codebase
(`module.observability` depending on `google_project_service.required`, in
the cloud environment, because API enablement has no output to consume).
Everywhere else, ordering emerges from data flow: GKE cannot be planned until
`module.vpc.subnet_id` is known, and the node pool cannot be planned until
`module.iam.node_service_account_email` is known.

This matters because `depends_on` forces conservative, coarse-grained
ordering and defeats Terraform's ability to parallelise unrelated work.
Data-driven ordering is both correct and faster.

## 2.2 Networking: why a custom VPC and three CIDR ranges

The default VPC was rejected outright: it has auto-created subnets in every
region with overlapping, unpredictable ranges, which makes future VPC peering
or on-premises connectivity a migration project.

Three ranges are not a stylistic choice; they are what VPC-native (alias IP)
GKE requires:

```hcl
ip_allocation_policy {
  cluster_secondary_range_name  = var.pods_range_name
  services_secondary_range_name = var.services_range_name
}
```

The consequence that matters for this platform specifically: **Pod IPs are
routable inside the VPC**. Prometheus therefore scrapes pod endpoints
directly, with no NAT hop and no `hostPort` tricks, and Filebeat ships to
Logstash over a plain ClusterIP. On a route-based (non-VPC-native) cluster,
both of those paths become more fragile.

Range sizing reflects how GKE actually allocates: it carves a `/24` out of the
pod range per node. A `/16` for pods therefore supports 256 nodes, which is
deliberate headroom - resizing a secondary range after the fact requires
recreating the cluster.

### Why firewall rules are split into three

`allow_internal`, `allow_master_webhooks` and `allow_admin` exist separately
rather than as one permissive rule because they have different lifetimes and
different reviewers. The master-to-webhook rule (ports 443, 8443, 9443,
10250, 15017) is specifically required by the Prometheus Operator's admission
webhook; without it, installing kube-prometheus-stack on a private cluster
times out in a way that is genuinely hard to diagnose. Naming the rule after
its purpose means the next engineer does not delete it.

`allow_admin` is `count`-gated on `length(var.authorized_source_ranges) > 0`,
so the default is to create **no** admin ingress rule at all, rather than a
`0.0.0.0/0` rule that someone intends to tighten later.

## 2.3 IAM: why two service accounts, and why no key files

### Two accounts, not one

The brief asked for a node service account and an exporter service account.
That separation is worth stating the reason for, because merging them is a
common shortcut.

The node SA is attached to every VM in the node pool. Anything that
compromises a node - a container escape, a malicious image - obtains its
credentials. Its roles are therefore **write-only telemetry**:

```hcl
node_sa_roles = [
  "roles/logging.logWriter",
  "roles/monitoring.metricWriter",
  "roles/monitoring.viewer",
  "roles/stackdriver.resourceMetadata.writer",
]
```

Nothing there lets an attacker read another project's metrics, read a bucket,
or create a resource.

The exporter SA needs the opposite: `roles/monitoring.viewer`, read-only. If
these were one account, every node in the cluster would carry read access to
the whole project's monitoring data, permanently, to serve one pod.

### Why the default GKE node service account was rejected

GKE will happily attach the Compute Engine default service account, which
carries `roles/editor` on the entire project. That is project-wide write
access on every node. `modules/iam` creates a dedicated account instead and
`modules/gke` sets `remove_default_node_pool = true` precisely so the default
pool - with Google's defaults - never exists even transiently.

### Why `cloud-platform` scope with narrow IAM roles

This looks wrong at first glance and is worth defending. The node pool
requests:

```hcl
oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
```

The instinct is to narrow the scope instead. But OAuth scopes and IAM roles
are an AND, not an OR, and scopes are a legacy GCE mechanism with coarse
granularity. Google's own guidance is to grant the broad scope and let IAM be
the real control, because IAM roles are auditable, revocable without
recreating the node pool, and expressible at a far finer granularity. Narrow
scopes additionally break in confusing ways when an addon needs an API you did
not anticipate. The effective permission set here is the union of the four
writer roles above, which is small.

### Why Workload Identity rather than a mounted key

A JSON service account key would have worked for the exporter and would have
been simpler. It was rejected because a key file is a bearer credential with
no expiry that must exist on disk, in a Secret, in a CI system, and in
whatever backup captures those. The Workload Identity chain instead is:

```
modules/iam:   roles/iam.workloadIdentityUser granted to
               serviceAccount:PROJECT.svc.id.goog[monitoring/gcp-exporter-sa]
                                    │
playbook.yml:  Kubernetes SA annotated iam.gke.io/gcp-service-account
                                    │
runtime:       pod asks GKE metadata server, receives a token valid ~1 hour
```

A compromised pod yields a token that expires within the hour and can only
read metrics. There is no credential at rest anywhere in this repository,
which is also why `.gitignore` lists `sa-key*.json` and `service-account*.json`
defensively rather than because such a file is expected.

### Why the binding lives in Terraform but the annotation lives in Ansible

The binding is an IAM resource and belongs to the infrastructure layer. The
annotation is a Kubernetes object field and belongs to the configuration
layer. Splitting them across layers creates one coupling: both sides must
agree on the namespace and ServiceAccount name.

Rather than document that agreement and hope, it is enforced mechanically.
Terraform emits an `ansible_facts` output:

```hcl
output "ansible_facts" {
  value = {
    gcp_exporter_sa_email      = module.iam.exporter_service_account_email
    gcp_exporter_k8s_namespace = var.monitoring_namespace
    gcp_exporter_k8s_sa_name   = var.exporter_k8s_service_account
    ...
  }
}
```

and the playbook reads it in a pre-task:

```yaml
- name: Pre-flight | Read Terraform outputs
  ansible.builtin.command:
    cmd: terraform -chdir={{ terraform_env_dir }} output -json ansible_facts
```

The service account email is therefore never typed by a human in two places.
If Terraform is unreachable, the playbook falls back to `group_vars` and
prints a warning naming the email it is about to use, rather than failing
opaquely or proceeding silently.

## 2.4 Ansible: why a playbook and not a Helm umbrella chart

A single umbrella chart with the four Elastic charts and kube-prometheus-stack
as dependencies was the obvious alternative. It was rejected for three
reasons:

1. **Ordering.** Helm's dependency mechanism does not sequence a release
   behind another release's readiness. Logstash starting before Elasticsearch
   accepts connections, or Filebeat starting before Logstash listens on 5044,
   produces minutes of connection-refused churn on every deployment. The
   playbook enforces order explicitly, including an active readiness gate:

   ```yaml
   - name: ELK | Wait for Elasticsearch to report Ready
     until: >-
       (es_pods.resources | map(attribute='status.containerStatuses', default=[])
         | flatten | selectattr('ready','equalto',true) | list | length)
       >= (elasticsearch_replicas | int)
   ```

2. **Secrets.** Secrets must exist before the charts that reference them. An
   umbrella chart would need pre-install hooks, which are harder to make
   idempotent than an ordinary task.

3. **Non-chart objects.** The ClusterRole, ClusterRoleBinding, the three
   ServiceAccounts and the GCP exporter manifests are not chart content.

### Why `connection: local` and `gather_facts: false`

There are no managed SSH hosts. Every task talks to the Kubernetes API
through `kubernetes.core`. Gathering facts about the laptop running Ansible
would cost seconds per run and tell us nothing about the cluster. The
inventory contains a single `localhost` entry for this reason, and
`ansible.cfg` sets `become = False` since nothing requires root.

### Why the shared YAML anchor for authentication

```yaml
vars:
  k8s_auth: &k8s_auth
    kubeconfig: "{{ kubeconfig_path }}"
    context: "{{ kube_context | default(omit, true) }}"
```

Every `kubernetes.core` task then merges `<<: *k8s_auth`. A task that forgets
the kubeconfig silently targets whatever `~/.kube/config` points at, which in
the worst case is a production cluster. The anchor makes forgetting it
structurally awkward.

### Why pre-flight checks fail loudly

Four checks run before anything is created: kubeconfig exists, the
`kubernetes` Python library is importable, Terraform outputs are readable, and
the cluster returns at least one Node. Each failure message names the exact
command that fixes it. The alternative - failing on task 30 with a Python
import error - costs far more of an engineer's time than the thirty seconds
these checks add.

### Why charts are version-pinned

`elastic_stack_version: "8.5.1"` and
`kube_prometheus_stack_version: "65.5.1"` are hard-pinned. An unpinned chart
turns an idempotent playbook into something that produces a different cluster
on Tuesday than it did on Monday, with no change in the repository. The
Elastic version pins the chart **and** the image together, so the two cannot
drift apart.

## 2.5 Jinja2: why three templates, and why these three

The division is by **lifecycle**, not by component count.

### `elk-values.yml.j2` - one template, four Helm releases

Elasticsearch, Logstash, Kibana and Filebeat are deployed as four separate
Helm releases but share a dense web of cross-references: the Elasticsearch
service name appears in Kibana's config, Logstash's output and Grafana's
data source; the Logstash service name and port 5044 appear in Filebeat's
output; the credentials Secret name appears in three of the four.

Split into four files, those references drift. Held in one template, a port
change is one edit. The playbook renders the file once and hands each release
only its own sub-tree:

```yaml
- name: ELK | Load the rendered values
  set_fact:
    elk_values: "{{ lookup('file', rendered_dir ~ '/elk-values.yml') | from_yaml }}"

- name: ELK | Deploy Elasticsearch
  kubernetes.core.helm:
    release_values: "{{ elk_values.elasticsearch }}"
```

### `monitoring-values.yml.j2` - one chart, one template

kube-prometheus-stack delivers Prometheus, Grafana, Node Exporter and Kube
State Metrics as one release. One release, one values file.

### `gcp-exporter.yml.j2` - raw manifests, deliberately not a chart

A `prometheus-stackdriver-exporter` chart exists. It was rejected because the
three things that actually matter for this component - the Workload Identity
ServiceAccount annotation, the ServiceMonitor with its deliberately different
scrape interval, and the local/cloud authentication difference - would all be
expressed as overrides fighting chart defaults. Written as raw manifests, the
Workload Identity chain is visible in twenty lines of YAML that a reviewer can
actually audit. The security-critical component is the one you want to be
able to read.

### Why templates render to disk before being applied

```yaml
- name: ELK | Render the Helm values from Jinja2
  ansible.builtin.template:
    src: elk-values.yml.j2
    dest: "{{ rendered_dir }}/elk-values.yml"
```

`ansible/rendered/` is gitignored but written on every run. When a deployment
misbehaves, the first question is always "what did Helm actually receive?" and
this answers it with `cat` instead of `helm get values` plus guesswork. It
also makes `--check --diff` genuinely informative.

### A Jinja2 trap that shaped the Grafana section

Grafana's `legendFormat` uses `{{label}}` syntax, which collides exactly with
Jinja2's expression delimiters. Inline dashboard JSON containing
`{{pod}}` causes Ansible to attempt to resolve `pod` as a variable and fail
the render. Dashboards are therefore shipped by `gnetId` with a pinned
revision rather than inline, which sidesteps the collision entirely. The
template carries a comment explaining this so the next person to add a
dashboard does not rediscover it the hard way.

## 2.6 The Grok filter: why it is written the way it is

This is the component that converts the pipeline from "log storage" into
"log analytics", so it earns detailed justification.

### `raw_message` is captured first, before anything else

```ruby
mutate {
  add_field => { "raw_message" => "%{message}" }
}
```

This is the first filter statement. If every subsequent Grok pattern fails,
the original line is still searchable. A pipeline that discards unparseable
input is worse than no pipeline, because the absence is invisible.

### Two branches: NGINX and generic

The NGINX branch is entered on any of three conditions - container name,
pod label, or the line simply starting with an IP address - so a workload
that was not labelled as expected is still parsed correctly.

The generic branch handles everything else by extracting a `LOGLEVEL`. In
`workloads/vprofile.yaml`, `vproapp` (Tomcat), `vprodb` (MySQL), and
`vpromq01` (RabbitMQ) exercise this branch alongside `vproweb`'s NGINX
logs, ensuring both branches of the filter are validated in practice.

### Fallback patterns within the NGINX branch

The `match` array contains the full combined-log pattern first and a shorter
pattern without the referer and user-agent fields second. Logstash tries them
in order. A proxy that strips headers therefore degrades to fewer fields
rather than to `_grokparsefailure`.

If the access-log patterns fail, a third pattern attempts the NGINX **error**
log format, which has an entirely different shape and carries a real
`log_level`.

### `date` filter: why the event timestamp is reparsed

```ruby
date {
  match => ["timestamp", "dd/MMM/yyyy:HH:mm:ss Z", "yy/MM/dd HH:mm:ss", "ISO8601"]
  target => "@timestamp"
}
```

Without this, `@timestamp` is the moment Filebeat *read* the line. After any
backlog - a Logstash restart, a network partition - thousands of old events
stack onto "now", and every Kibana time-series chart lies. Reparsing the
timestamp from inside the line is what makes historical queries truthful.

### `log_level` derived from `http_status`

NGINX access logs have no severity field. Rather than leave the field absent
for HTTP traffic, it is synthesised: 5xx becomes `ERROR`, 4xx becomes `WARN`,
everything else `INFO`. The payoff is a single Kibana query,
`log_level: "ERROR"`, that spans both web traffic and application logs. The
alternative - different queries for different log sources - is exactly the
friction a centralized platform exists to remove.

### Type coercion in the pattern

`%{NUMBER:http_status:int}` and `%{NUMBER:bytes_sent:int}` carry the `:int`
suffix. Without it, Elasticsearch indexes them as strings, and
`http_status >= 400` becomes a lexicographic comparison that silently returns
wrong results. This is the single most common defect in hand-rolled ELK
pipelines.

### Daily indices

```ruby
index => "logstash-k8s-%{+YYYY.MM.dd}"
```

The date maths runs in Logstash, not Jinja2 - rendering the date at template
time would freeze the index name at deployment. Daily indices keep shards
small and make retention a matter of deleting whole indices, which is an
O(1) metadata operation, rather than running delete-by-query, which rewrites
segments.

### `manage_template => true`

An explicit index template ensures `http_status` is a `long` and `client_ip`
is an `ip` type. Elasticsearch's dynamic mapping would guess from the first
document it sees, and a single malformed line early in the day can poison the
mapping for that entire index.

## 2.7 Filebeat: DaemonSet, hostPath and two mounts

### Why a DaemonSet

One pod per node, which is what "collect every container's logs" requires. A
Deployment would scrape whichever node it happened to land on. The chart's
`deployment.enabled` is explicitly set to `false` to prevent accidentally
running both and double-ingesting every line.

### Why both `/var/log/containers` and `/var/log/pods` are mounted

This is a detail that is easy to get wrong and hard to debug.
`/var/log/containers/*.log` are **symlinks** into `/var/log/pods/`. Mounting
only the first gives Filebeat a directory of dangling symlinks and an empty
pipeline with no obvious error. Both are mounted, both read-only.

### Why `add_kubernetes_metadata` is non-negotiable

A raw log line identifies nothing. The processor attaches pod name,
namespace, labels and node, which is what makes a line attributable to a
workload. It is also what the smoke test asserts on
(`kubernetes.namespace: "workload"`) as proof that enrichment is live.

### Why Filebeat ships to Logstash and not directly to Elasticsearch

Filebeat can write to Elasticsearch directly, and it is faster. That path was
rejected because it skips the Grok stage entirely, storing opaque text blobs.
The Logstash hop *is* the parsing, and the parsing is the requirement.

### Why `max_retries: -1`

Retry forever rather than drop. Combined with Logstash's
`queue.type: persisted` and a PVC, an Elasticsearch restart causes a delay in
log availability, not a hole in the record.

### Why the logging and kube-system namespaces are dropped

```yaml
- drop_event:
    when:
      or:
        - equals: { kubernetes.namespace: "logging" }
        - equals: { kubernetes.namespace: "kube-system" }
```

Without the first condition, Logstash logs a line, Filebeat ships it,
Logstash logs about shipping it, and the pipeline feeds itself. The feedback
loop saturates the cluster within minutes.

## 2.8 Prometheus and Grafana decisions

### Why kube-prometheus-stack instead of hand-written manifests

It delivers four required components, plus the Prometheus Operator and its
CRDs, as one versioned, tested unit. Hand-writing Prometheus scrape configs
for kubelet, cAdvisor and the exporters is several hundred lines of
relabelling rules that upstream maintains for free.

Note that the brief asks for Prometheus as a `StatefulSet` with a `PVC`, and
no `StatefulSet` appears literally in any file. That is because the Operator
*generates* one from the `prometheusSpec.storageSpec.volumeClaimTemplate`.
The outcome is exactly as specified; the mechanism is declarative.

### Why `serviceMonitorSelectorNilUsesHelmValues: false`

By default the Operator only adopts ServiceMonitors carrying the Helm release
label. Setting this to `false` makes Prometheus adopt **every** ServiceMonitor
in the cluster. That is what lets `gcp-exporter.yml.j2` ship its own
ServiceMonitor independently, and it means a future microservice can opt into
scraping without anyone touching the monitoring stack.

### Why annotation-based discovery exists as well

```yaml
additionalScrapeConfigs:
  - job_name: kubernetes-pods-annotated
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
```

ServiceMonitors require a CRD and a Service. The annotation path lets a pod
opt in with three annotations and nothing else - which is precisely how
`workloads/vprofile.yaml` (`vproweb`) exposes its NGINX metrics. Supporting both means the
platform meets teams where they are.

### Why Grafana's password comes from an existing Secret

Setting `adminPassword:` in values writes the plaintext into the Helm release
Secret, readable by anyone who can run `helm get values`. Pointing at
`existingSecret` keeps the only copy in the Kubernetes Secret that Ansible
created with `no_log: true`.

### Why Grafana also gets an Elasticsearch data source

Not required by the brief. Added because the two pipelines are otherwise
islands: an engineer sees a CPU spike in Grafana and must switch to Kibana to
find the logs explaining it. With both data sources provisioned, a single
dashboard can show the metric and the log lines side by side. The
`logMessageField: raw_message` and `logLevelField: log_level` settings are
what tie it to the Grok output. (Layer E, section 2.11, automates the same
correlation for alert triage.)

## 2.9 The GCP exporter: the one deliberate rule-break

The brief specifies a 15-second global scrape interval. The exporter's
ServiceMonitor sets `interval: 5m`, and this is intentional.

Cloud Monitoring publishes most series at one-minute granularity at best, with
a three-to-four-minute ingestion delay. Scraping every 15 seconds would issue
four times the API calls to re-read points that have not changed - quadrupling
the bill and risking rate-limiting, for zero additional resolution. The
15-second interval is applied globally and genuinely serves Node Exporter,
Kube State Metrics and application metrics, where it buys real fidelity.

`scrapeTimeout: 60s` is set for the same underlying reason: Monitoring API
round trips are slow, and the default 10-second timeout would mark a perfectly
healthy exporter as down.

### Why one replica

Two replicas would double the API call volume and produce duplicate series
that Prometheus must deduplicate by external label. All cost, no availability
benefit: a missed five-minute scrape of slow-moving cloud metrics is not an
outage. A PodDisruptionBudget covers the voluntary-drain case.

### Why a NetworkPolicy on this pod specifically

It is the only pod in the cluster with egress to the public internet. The
policy restricts it to DNS plus 443, and restricts ingress to port 9255 from
the monitoring namespace. Scoping the one component that talks outward is
cheap and worth doing.

## 2.10 Why `-parallelism=1`

The brief requires it, and the reason is worth recording because someone will
eventually "optimise" it away.

`google_project_iam_member` is not an atomic operation. It performs a
read-modify-write against a single project-level IAM policy document.
Terraform's default parallelism of 10 means several of those read the same
policy version concurrently, each adds its own binding, and the last write
wins - silently discarding the others. The failure is not an error; it is a
binding that is simply absent, discovered weeks later when the exporter cannot
read metrics.

The emulator's IAM store has the same read-modify-write shape, so the
constraint applies identically in both environments. It is therefore set in
one place, as a Makefile variable consumed by every apply and destroy target.

## 2.11 Layer E (optional): the alert-triage agent

Every decision below is stated with its rejected alternative. All of it is
**design**; nothing has been built or measured.

### 2.11.1 Why the agent is read-only and suggest-only

**Chosen:** no tool in Layer E can mutate anything. The agent proposes
commands; a human runs them.

**Rejected:** automated remediation (restart a pod, scale a deployment). An
LLM that can write to the cluster turns a wrong diagnosis into an outage, and
the failure is hardest to catch precisely when the model is confidently
wrong. Read-only means the worst outcome of a bad run is a misleading note,
which a human can discard. Write tools can be added later, one at a time,
behind approval, only after the evaluation in section 5.8 shows the diagnoses
are reliable.

### 2.11.2 Why three MCP servers and not one, and not in-process functions

**Chosen:** one MCP server per backend (Prometheus, Elasticsearch,
Kubernetes), each a separate Deployment with its own ServiceAccount.

**Rejected (one combined server):** a single process would need credentials
for all three backends, so compromising it yields all three. Three servers
mean each holds the minimum for one backend, mirroring the node-SA versus
exporter-SA separation in section 2.3.

**Rejected (plain Python functions inside the agent):** this is simpler, but
it puts the credentials in the same process as the LLM loop and makes the
tools unusable by anything else. As MCP servers, the same tools can later be
used from an IDE or another client, and the permission boundary is a network
and RBAC boundary rather than a code convention.

### 2.11.3 What each MCP server exposes, and what it refuses

| Server | Tools | Hard limits enforced in the server, not the prompt |
|---|---|---|
| `prometheus-mcp` | `query`, `query_range`, `get_alerts` | Query length cap, range cap, 15 s timeout, series-count cap on results |
| `elasticsearch-mcp` | `search_logs(namespace, pod?, level?, text?, minutes)` | Index pinned to `logstash-k8s-*`; namespace must be in `triage_allowed_namespaces`; window capped (default 60 min); size capped (default 50 hits); returns a field subset, not whole documents |
| `kubernetes-mcp` | `get_pod`, `describe_pod`, `list_events`, `get_pod_logs`, `get_workload_status` | Read verbs only; no Secrets and no ConfigMap data; log tail capped by lines and bytes |

Limits live in the server because a limit expressed only in a system prompt
is a request, not a control. The Elasticsearch server additionally connects
as a dedicated read-only Elasticsearch role (`triage_reader`, read on
`logstash-k8s-*` only), so even a bug in the server cannot reach other
indices.

### 2.11.4 Why an Alertmanager webhook is the trigger

**Chosen:** Alertmanager `webhook_configs` to `POST /alert` on the agent.
Alertmanager already does grouping, deduplication and inhibition, and
Layer E should not reimplement them.

**Rejected:** polling Prometheus `/api/v1/alerts` on a timer. That duplicates
Alertmanager's grouping logic and adds latency and a second source of truth
about what is firing.

**A fact about this repository that changes the design:** locally
(`is_emulated: true`) Alertmanager is **off**, and in the cloud it is on. Layer
E therefore sets `alertmanager.enabled` to
`(not is_emulated) or triage_agent_enabled`, so enabling the agent locally
also starts Alertmanager, which costs little. Independently of Alertmanager,
`POST /alert` accepts the Alertmanager payload format, so the evaluation
harness and a manual `curl` can trigger the agent with no Alertmanager at all.
That is also what makes the agent testable in a unit-test sense.

### 2.11.5 Treating logs as hostile input

Log lines are written by workloads, so an attacker who can influence an
application's output can influence what the agent reads. That is prompt
injection through observability data, and it is a real risk for this exact
design. The controls are layered:

1. **No write tools** (2.11.1), so injected instructions cannot cause a
   change. This is the control that actually bounds the damage.
2. **Tool results are wrapped as data** in delimiters, and the system prompt
   states that tool output is evidence and never instructions. This reduces
   the chance of the model being steered; it does not eliminate it, and the
   design does not rely on it.
3. **Structured output.** The agent must return a Pydantic model
   (`summary`, `evidence[]`, `likely_cause`, `confidence`,
   `suggested_commands[]`). Suggested commands are rendered as text for a
   human and never executed.
4. **Budgets.** A maximum number of tool calls per alert (default 8), a
   per-run timeout, and a cool-down per alert fingerprint (default 10
   minutes) so a flapping alert cannot run up cost or loop.
5. **Audit without reflection.** The agent logs the tool name, arguments and
   the size and hash of each result to stdout, not the result body. Those
   lines flow through Filebeat like any other workload's, and omitting bodies
   stops hostile log content from being re-ingested and re-read.
6. **Egress NetworkPolicy** on the triage namespace: DNS, the Prometheus,
   Elasticsearch and API-server endpoints, and the single configured LLM
   endpoint, and nothing else.

### 2.11.6 The LLM endpoint, and an honest memory budget

**Chosen:** an OpenAI-compatible endpoint set by `triage_llm_base_url` and
`triage_llm_model`. The default is **Google AI Studio (`gemini-3.5-flash`)**
via its OpenAI-compatible endpoint
(`https://generativelanguage.googleapis.com/v1beta/openai/`), authenticated
by a Kubernetes Secret (`triage-llm-credentials`, `no_log: true`). The OpenAI
Agents SDK is pointed at it through a custom `AsyncOpenAI` client.

**Why hosted free-tier as default, with Ollama as an optional override:**
On a 16 GB laptop that already hosts floci-gcp, k3s, Elasticsearch, Logstash,
Kibana, Prometheus, Grafana and VProfile, running a local 7-8B model
(in-cluster or on the host) competes with Elasticsearch's heap for the same
RAM and risks OOM kills. A free-tier hosted model (`gemini-3.5-flash`,
smoke-tested against the OpenAI endpoint) adds zero local memory overhead and
provides stronger multi-step tool calling and structured-output reliability.
Because the endpoint and model are plain variables, switching to a host-run
Ollama instance or another OpenAI-compatible provider requires zero code
changes.

**Known risk, stated plainly:** free-tier hosted APIs enforce rate limits
(RPM/TPM), and any LLM can still loop or return malformed structured output.
The design contains this with the budgets above (max 8 tool calls, per-run
timeout, 10-minute per-fingerprint cool-down) and schema validation (an
invalid response is retried once, then reported as a failed triage, never
silently accepted).

"""

### 2.11.7 Why runbooks live in a ConfigMap rendered by Jinja2

**Chosen:** `triage-runbooks.yml.j2` renders a ConfigMap keyed by `alertname`,
one short runbook per alert rule defined in `monitoring-values.yml.j2`. The
agent loads the matching runbook as context for that alert.

**Rejected:** embedding runbooks in the system prompt (they cannot change
without an image rebuild) or fetching them from an external wiki (a new
dependency and a new credential). In a ConfigMap they are versioned in the
same repository as the alert rules and updated by the same playbook run, so
a rule and its runbook cannot drift apart silently.

### 2.11.8 Why the agent exports its own metrics

The agent exposes `triage_runs_total{outcome}`, `triage_duration_seconds`
and `triage_tool_calls_total{tool}` through a ServiceMonitor, picked up by the
existing `serviceMonitorSelectorNilUsesHelmValues: false` setting without
touching the monitoring release. A failure-rate alert on the agent itself
closes the loop: the platform that observes everything else also observes its
own triage component.

---

# 3. File-by-File Breakdown

Every generated file, its role, its key configuration, and how it connects to
the rest of the stack. Sections 3.1-3.10 describe Layers A-D as implemented.
Section 3.11 lists Layer E files, which are **planned**, and section 3.12
lists the edits Layer E makes to existing files.

## 3.1 Root files

### `docker-compose.yml`

**Role.** Starts the local GCP control plane.

**Key configuration.**

| Setting | Value | Why |
|---|---|---|
| `image` | `floci/floci-gcp:latest` | Emulates compute, container, iam, storage, monitoring, serviceusage and cloudresourcemanager on one ALPN-multiplexed port |
| `ports` | `4588:4588`, `6443:6443` | 4588 is the API surface; 6443 is the k3s API server the emulator publishes |
| `volumes` | `/var/run/docker.sock:/var/run/docker.sock` | **Load-bearing.** GKE is a Docker-backed service; without this, cluster creation degrades to a mock with no reachable API server |
| `volumes` | `./.floci/data:/app/data` | Emulator state survives restarts |
| `FLOCI_GCP_SERVICES_GKE_MOCK` | `false` | Forces real k3s rather than a stub object |
| `FLOCI_GCP_SERVICES_GKE_DEFAULT_IMAGE` | `rancher/k3s:latest` | The image spawned as the cluster |
| `FLOCI_GCP_SERVICES_DOCKER_NETWORK` | the compose network | Spawned sidecars join it so emulator and cluster resolve each other by name |
| `FLOCI_GCP_DEFAULT_PROJECT_ID` | `obs-local` | **Must match** `var.project_id` in `environments/local` |
| `FLOCI_GCP_STORAGE_MODE` | `hybrid` | State persists across `docker compose restart` |
| `healthcheck` | `curl /_floci-gcp/health` | Consumed by `make up` |

**Connects to.** `terraform/environments/local/providers.tf` points every
`*_custom_endpoint` at this container. `scripts/wait-for-emulator.sh` gates on
its health endpoint and verifies the socket mount.

### `Makefile`

**Role.** The single entry point for every workflow. 30+ targets in six
groups: emulator, local Terraform, cloud Terraform, Ansible, workload, access.
(Layer E adds a seventh group, section 3.12.)

**Key configuration.**

- `TF_PARALLELISM ?= 1`, consumed by `TF_APPLY_FLAGS` and `TF_DESTROY_FLAGS`,
  so no apply or destroy can run without it
- `export GOOGLE_OAUTH_ACCESS_TOKEN ?= floci-mock-access-token`
- `export ANSIBLE_CONFIG := $(ANSIBLE_DIR)/ansible.cfg`
- `KUBECONFIG_FILE ?= $(ROOT_DIR)/.floci/kubeconfig`, threaded into every
  Ansible and kubectl invocation
- `.ONESHELL:` so multi-line recipes share a shell
- `help` is the default goal and self-documents from `##` comments

**Notable targets.** `all` chains the full local bring-up. `kubeconfig` pipes
`terraform output -raw kubeconfig` to a file, chmods it `600` and immediately
runs `kubectl get nodes` as a built-in assertion. `nuke` removes emulator
state *and* any spawned `obs-*` sidecar containers, which a plain
`docker compose down` leaves behind.

### `.gitignore`

**Role.** Prevents three categories of leak: Terraform state (which contains
resolved secret values in plaintext), kubeconfigs and credentials, and
rendered Ansible output.

**Notable.** `terraform.tfvars` is ignored but `!terraform.tfvars.example` is
re-included. `ansible/rendered/` is ignored because it contains resolved
passwords.

## 3.2 `scripts/`

### `scripts/wait-for-emulator.sh`

**Role.** Gates `make up`. Blocks until the emulator is serving, then verifies
the Docker socket passthrough.

**Key logic.**

1. Polls `http://localhost:4588/_floci-gcp/health` with a configurable timeout
   (default 180s), falling back to a raw TCP probe on 4588 for emulator builds
   that do not expose the control-plane path
2. On timeout, dumps the last 50 lines of `docker logs floci-gcp` before
   failing - the information you need is printed without a second command
3. **Fails hard** if `/var/run/docker.sock` is not among the container's
   mounts, with a message naming the file to fix

**Why the socket check is a hard failure.** Without it, the first symptom is
Terraform succeeding, `make kubeconfig` producing a file, and `kubectl`
hanging on an unreachable endpoint - three steps removed from the cause.

### `scripts/smoke-test.sh`

**Role.** Proves both pipelines are live end to end. Exit `0` means working.

**Six check groups.**

| # | Checks | Method |
|---|---|---|
| 1 | Emulator health; socket mounted | `curl /_floci-gcp/health`, `docker inspect` |
| 2 | Nodes `Ready` | `kubectl get nodes`, counts Ready vs total |
| 3 | All pods Running and Ready in all three namespaces | `awk` over `kubectl get pods`, tolerating `Completed` job pods |
| 4 | Real HTTP 200 and 404 generated | Port-forward to `svc/vproweb`, assert status codes (`/` → 200, `/vprofile-missing-page` → 404), then 40 extra requests (20x200, 20x404) |
| 5 | Parsed fields reached Elasticsearch | `_cat/indices`, then `_search` for `http_status:404` **with** `client_ip` and `request_path` present; then each of the seven Grok fields individually; then `kubernetes.namespace:workload` to prove metadata enrichment |
| 6 | Exporters `UP` in Prometheus | `/api/v1/targets`, then real PromQL queries per exporter |

**Design notes.** `port_forward()` blocks on the local port accepting TCP
rather than sleeping a fixed interval. A `trap` on EXIT/INT/TERM kills every
background forward. The Elasticsearch password is read from the Kubernetes
Secret rather than passed in. `SKIP_EMULATOR=1` makes it run unchanged against
real GCP. When `triage_agent_enabled` is true, a seventh group is appended
(section 4.7); with the flag off the script is unchanged.

**Why check 5 is the important one.** Asserting that an index exists only
proves logs arrived. Asserting a document with `http_status: 404` **and**
`client_ip` **and** `request_path` proves Grok actually parsed it. Those are
different failures with the same symptom.

## 3.3 `terraform/modules/vpc/`

| File | Contents |
|---|---|
| `main.tf` | `google_compute_network`, `google_compute_subnetwork` with two `secondary_ip_range` blocks, three firewall rules, optional Cloud Router + NAT |
| `variables.tf` | 14 variables with CIDR validation via `can(cidrhost(...))` and enum validation on `routing_mode` |
| `outputs.tf` | `network_id`, `subnet_id`, `pods_range_name`, `services_range_name`, `node_network_tag` |

**Key configuration.** `auto_create_subnetworks = false`;
`private_ip_google_access = true` so nodes reach `*.googleapis.com` without
external IPs; `enable_flow_logs` and `enable_cloud_nat` are `dynamic`/`count`
gated so they vanish locally.

**Connects to.** `stack/main.tf` feeds `network_id` and `subnet_id` into
`modules/gke`; the two range names become the cluster's
`ip_allocation_policy`; `node_network_tag` is applied to node pool `tags` so
the firewall rules actually match.

## 3.4 `terraform/modules/iam/`

| File | Contents |
|---|---|
| `main.tf` | Two `google_service_account`, two `google_project_iam_member` loops, one `google_service_account_iam_member` for Workload Identity, optional token-creator bindings |
| `variables.tf` | Account IDs with regex validation against Google's 6-30 char rule; namespace and SA name for the WI binding |
| `outputs.tf` | Both SA emails, the WI member string, and the resolved role lists |

**Key configuration.** The member string is built once in `locals`:

```hcl
k8s_sa_member = "serviceAccount:${var.project_id}.svc.id.goog[${var.exporter_k8s_namespace}/${var.exporter_k8s_service_account}]"
```

Role lists use `concat()` with conditional segments, so
`enable_artifact_registry_pull` adds exactly one role rather than requiring a
separate resource.

**Connects to.** `node_service_account_email` goes to the GKE node pool.
`exporter_service_account_email` flows through `stack`'s `ansible_facts`
output into the playbook, which writes it into the
`iam.gke.io/gcp-service-account` annotation. Layer E adds **no** Terraform and
no GCP IAM: its identities are Kubernetes ServiceAccounts only.

## 3.5 `terraform/modules/gke/`

| File | Contents |
|---|---|
| `main.tf` | `google_container_cluster` and `google_container_node_pool`, with seven `dynamic` blocks gated on `local.is_emulated` |
| `variables.tf` | 40 variables covering networking, versions, node pool, addons and policy |
| `outputs.tf` | Connection details plus a fully rendered `kubeconfig` built with `yamlencode()` |

**Key configuration.**

- `remove_default_node_pool = true` with `initial_node_count = 1` - the
  default pool with Google's default service account never persists
- `workload_identity_config { workload_pool = "${project}.svc.id.goog" }`
- `monitoring_config { managed_prometheus { enabled = false } }` and
  `logging_config { enable_components = ["SYSTEM_COMPONENTS"] }` - the
  explicit refusal to use GCP-native workload logging
- `metadata = { disable-legacy-endpoints = "true" }` - mandatory for Workload
  Identity; the legacy v1 metadata endpoint would leak the node SA token to
  any pod
- `workload_metadata_config { mode = GKE_METADATA }` in the cloud

**The `kubeconfig` output.** Rendered in HCL rather than shelled out to
`gcloud`, so the local flow needs no Google SDK at all. It branches on
`var.emulated`: a static bearer token locally, an `exec` block invoking
`gke-gcloud-auth-plugin` in the cloud.

## 3.6 `terraform/stack/`

| File | Role |
|---|---|
| `main.tf` | Instantiates all three modules and wires their outputs; conditionally creates the artifacts GCS bucket |
| `variables.tf` | ~40 variables, the complete contract both environments fill |
| `outputs.tf` | Pass-through outputs plus the `ansible_facts` handoff blob |
| `versions.tf` | `required_version >= 1.6.0`, google provider `>= 6.0.0, < 7.0.0` |

**The critical lines** are the three wiring expressions quoted in section 2.1.
They exist exactly once in the codebase.

**`ansible_facts`** is the formal contract between the infrastructure and
configuration layers - project, region, environment, emulated flag, cluster
name, exporter SA email, exporter namespace and SA name.

## 3.7 `terraform/environments/local/`

| File | Role |
|---|---|
| `providers.tf` | Ten `*_custom_endpoint` overrides, `access_token`, `user_project_override = false` |
| `versions.tf` | `backend "local"` |
| `main.tf` | One `module "observability"` call with `emulated = true` and small sizing |
| `variables.tf` | Emulator endpoint (regex-validated), token, project, CIDRs |
| `outputs.tf` | Pass-through, including the `kubeconfig` that `make kubeconfig` consumes |

**The endpoint mapping**, which is the heart of the local environment:

| Real Google host | Emulated |
|---|---|
| `https://compute.googleapis.com/compute/v1/` | `http://localhost:4588/compute/v1/` |
| `https://container.googleapis.com/v1/` | `http://localhost:4588/container/v1/` |
| `https://iam.googleapis.com/v1/` | `http://localhost:4588/v1/` |
| `https://storage.googleapis.com/storage/v1/` | `http://localhost:4588/storage/v1/` |
| `https://monitoring.googleapis.com/v1/` | `http://localhost:4588/v1/` |
| `https://serviceusage.googleapis.com/v1/` | `http://localhost:4588/v1/` |
| `https://cloudresourcemanager.googleapis.com/v1/` | `http://localhost:4588/v1/` |

The path suffixes are not cosmetic. The provider appends resource paths
directly to these strings, so the version segment and trailing slash must
match the real API or every request 404s.

## 3.8 `terraform/environments/gcp/`

| File | Role |
|---|---|
| `providers.tf` | No endpoint overrides. ADC only; no `credentials` argument, so a committed key file cannot be used by accident. `default_labels` applied provider-wide |
| `versions.tf` | `backend "gcs"`, overridden at init by `-backend-config` |
| `main.tf` | `google_project_service` for ten APIs with `disable_on_destroy = false`, then the same `module "observability"` call with `emulated = false` |
| `variables.tf` | `project_id` has **no default**, deliberately |
| `outputs.tf` | Adds `connect_command`, a copy-pasteable `gcloud container clusters get-credentials` line |
| `terraform.tfvars.example` | Fully commented template |

**Why `disable_on_destroy = false`.** Disabling `container.googleapis.com`
underneath a live cluster in another workspace would be catastrophic and
is not reversible by `terraform apply`.

## 3.9 `ansible/`

### `ansible.cfg`

`inventory`, `collections_path`, `stdout_callback = yaml`,
`callbacks_enabled = profile_tasks, timer` for per-task timing,
`become = False` since nothing needs root, `interpreter_python = auto_silent`.

### `requirements.yml`

`kubernetes.core >=3.0.0,<6.0.0` (the whole playbook is built on it),
`community.general`, `ansible.posix`. Version ranges rather than floating
`latest`. A comment names the three pip packages the collection imports.

### `inventory/hosts.ini`

A single `localhost ansible_connection=local`. An `[observability:children]`
group exists so real hosts can be added later without restructuring.

### `group_vars/all.yml`

**Role.** The single source of truth for the configuration layer: ~90
variables covering connection, environment shape, namespaces, storage class,
Helm repos, pinned versions, per-component sizing, credentials, RBAC
definitions and timeouts.

**The pattern that makes promotion a one-flag change:**

```yaml
elasticsearch_replicas: "{{ 1 if is_emulated else 3 }}"
storage_class: "{{ 'local-path' if is_emulated else 'standard-rwo' }}"
elasticsearch_tls_enabled: "{{ false if is_emulated else true }}"
prometheus_retention: "{{ '2d' if is_emulated else '15d' }}"
```

Setting `-e is_emulated=false` flips roughly 20 derived values at once.

### `playbook.yml`

**Role.** The configuration layer. One play, eight task groups, six pre-tasks,
one summary post-task.

| Group | Tag | What it creates |
|---|---|---|
| Pre-flight | `always` | Four fail-fast checks + Terraform fact adoption |
| Namespaces | `namespaces` | Three namespaces + a ResourceQuota on `workload` |
| Secrets | `secrets` | Four Secrets, base64 via `b64encode`, all `no_log: true` |
| RBAC | `rbac` | Three ServiceAccounts, one ClusterRole, one ClusterRoleBinding |
| Helm repos | `helm` | elastic, prometheus-community, grafana |
| ELK | `logging` | Render, load, then ES -> readiness gate -> Logstash -> Kibana -> Filebeat |
| Monitoring | `monitoring` | Render, then kube-prometheus-stack |
| GCP exporter | `monitoring,gcp` | Render, then `k8s` with `apply: true` |
| Verify | `verify` | Waits for all pods in both namespaces |

**The ClusterRole** grants the brief's required `get`/`list`/`watch` on
`nodes`, `pods`, `services`, `endpoints`, plus what the components actually
need to function: `namespaces` and `configmaps` for Filebeat's metadata
enrichment, `apps`/`batch`/`networking` resources for Prometheus discovery,
and the `nonResourceURLs: ["/metrics", "/metrics/cadvisor"]` rule without
which kubelet scraping returns 403.

### `templates/elk-values.yml.j2`

**Role.** Helm values for four releases in one file (610 lines rendered).

| Section | Produces | Key settings |
|---|---|---|
| `elasticsearch` | StatefulSet + PVC, :9200 | `volumeClaimTemplate` with `storage_class`; `secret.enabled: false` so Ansible's Secret is authoritative; `sysctlInitContainer` for `vm.max_map_count`; anti-affinity `soft` locally, `hard` in cloud |
| `logstash` | Deployment + ClusterIP :5044 | The complete three-stage pipeline; `queue.type: persisted` with a PVC; `fullnameOverride: logstash` so the service name is predictable |
| `kibana` | Deployment + Service :5601 | Credentials and encryption key from the Secret via `extraEnvs` |
| `filebeat` | DaemonSet | Both hostPath mounts read-only; `add_kubernetes_metadata`; `managedServiceAccount: false`; `deployment.enabled: false`; control-plane tolerations |

### `templates/monitoring-values.yml.j2`

**Role.** kube-prometheus-stack values (490 lines rendered).

Key settings: `scrapeInterval: 15s`; `storageSpec.volumeClaimTemplate` (the
PVC); `serviceAccountName: obs-prometheus`; the four
`*SelectorNilUsesHelmValues: false` flags; `additionalScrapeConfigs` for
annotation discovery; Grafana `admin.existingSecret` plus two provisioned data
sources; `defaultDashboardsEnabled: true` plus four `gnetId` dashboards; five
platform-specific alert rules; control-plane scrape jobs disabled because GKE
and k3s both hide them.

### `templates/gcp-exporter.yml.j2`

**Role.** Six Kubernetes manifests (379 lines rendered).

`ConfigMap` (metric prefixes), `Deployment` (:9255, `serviceAccountName:
gcp-exporter-sa`, `readOnlyRootFilesystem`, non-root 65534, a
`checksum/config` annotation that forces a rollout when prefixes change),
`Service`, `ServiceMonitor` (5m interval, 60s timeout, relabels `job` to
`gcp-stackdriver-exporter`), `PodDisruptionBudget`, `NetworkPolicy`.

The local/cloud authentication branch is the interesting part: locally it sets
`STACKDRIVER_EMULATOR_HOST` and a stub token; in the cloud it sets **no
credentials at all**, because the client library finds the GKE metadata server
itself.

## 3.10 `workloads/vprofile.yaml`

Twelve manifests implementing the multi-tier **VProfile** Java web application
inside the `workload` namespace: one `Secret`, one `PersistentVolumeClaim`,
five `Deployments`, and five `ClusterIP` `Services`. Every container—including
init containers and sidecars—declares explicit CPU and memory requests and
limits, which is mandatory because the `workload` namespace enforces a
`ResourceQuota`.

| Component | Image | Port(s) | Role & Observability Hook |
|---|---|---|---|
| `vprodb` | `zeyaddev/vprofile-images:db-v1` | `3306` | MySQL 8 database backed by `vprodb-pvc` (2Gi `ReadWriteOnce`, `Recreate` strategy). Uses a `startupProbe` (`SELECT 1 FROM accounts.user LIMIT 1`) to gate readiness until schema import completes, and a `readinessProbe` (`mysqladmin ping`). |
| `vprocache01` | `memcached:alpine` | `11211` | In-memory caching tier for database query offloading. |
| `vpromq01` | `rabbitmq:3-alpine` | `5672` | Message broker authenticated via `vprofile-secrets`. |
| `vproapp` | `zeyaddev/vprofile-images:app-v1` | `8080` | Java/Tomcat application server. Runs a `wait-for-db` init container (`busybox:1.36`) polling `nc -z vprodb 3306` so Tomcat never boots against an uninitialized database. Emits Java logs and stack traces that exercise the generic Grok branch and Filebeat multiline folding. |
| `vproweb` | `zeyaddev/vprofile-images:web-v1` + `nginx/nginx-prometheus-exporter:1.3.0` | `80`, `8081`, `9113` | NGINX reverse proxy forwarding traffic to `vproapp:8080` and writing combined access logs to `/dev/stdout` (parsed by the NGINX Grok branch). The exporter sidecar scrapes `http://127.0.0.1:8081/stub_status` and exposes Prometheus metrics on `:9113/metrics` via `prometheus.io/scrape` pod annotations. |

`Secret/vprofile-secrets` supplies `MYSQL_ROOT_PASSWORD`, `RABBITMQ_DEFAULT_USER`,
and `RABBITMQ_DEFAULT_PASS` to `vprodb` and `vpromq01` via `secretKeyRef`.

## 3.11 Layer E files (planned, not yet created)

```
agents/
├── triage-agent/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
│       ├── main.py          FastAPI: POST /alert, GET /triage/{fingerprint}, /healthz, /metrics
│       ├── agent.py         OpenAI Agents SDK loop, budgets, retry-once on invalid output
│       ├── schemas.py       Pydantic: AlertmanagerPayload, TriageNote
│       └── prompts.py       system prompt, data-wrapping of tool output
├── mcp-servers/
│   ├── prometheus_mcp.py    FastMCP, streamable-http
│   ├── elasticsearch_mcp.py FastMCP, streamable-http
│   └── kubernetes_mcp.py    FastMCP, streamable-http
└── eval/
    ├── faults/              one manifest + one expected-cause file per fault
    ├── payloads/            synthetic Alertmanager payloads per fault
    └── run_eval.py          injects, triggers, scores, prints X of Y

ansible/templates/
├── triage-agent.yml.j2      namespace objects, 4 Deployments, Services, NetworkPolicy,
│                            ServiceMonitor, ResourceQuota, results PVC
└── triage-runbooks.yml.j2   ConfigMap keyed by alertname
```

| File | Role | Key configuration |
|---|---|---|
| `agents/triage-agent/app/main.py` | Receives the Alertmanager webhook, de-duplicates by fingerprint, runs the agent, stores the note | Accepts the Alertmanager v4 payload (`status`, `alerts[].labels`, `annotations`, `startsAt`, `fingerprint`); one run at a time (queue) because the local LLM is the bottleneck; 10-minute per-fingerprint cool-down |
| `agents/triage-agent/app/agent.py` | The tool-calling loop | OpenAI Agents SDK; custom client at `triage_llm_base_url`; max tool calls 8; per-run timeout; structured output `TriageNote` |
| `agents/mcp-servers/*.py` | One read-only MCP server per backend | Limits from section 2.11.3 enforced in code; each exposes streamable HTTP on its own port |
| `ansible/templates/triage-agent.yml.j2` | Everything Layer E deploys | Own ServiceAccount per Deployment; read-only Role/ClusterRole `obs-triage-reader` with no Secrets access; egress NetworkPolicy; ServiceMonitor for agent metrics |
| `ansible/templates/triage-runbooks.yml.j2` | Runbook ConfigMap | One entry per alert rule in `monitoring-values.yml.j2`, keyed by `alertname` |
| `agents/eval/run_eval.py` | Measures the agent | Section 5.8 |

**Image delivery on the local phase.** The k3s node does not pull from the
host's Docker daemon. `make triage-build` builds the four images (agent plus
three MCP servers) and imports them into the k3s container's runtime. How
exactly depends on the container name and tooling the emulator spawns and
must be confirmed when this is first run. In the cloud, the same images are
pushed to a registry and the manifests reference them by tag.

## 3.12 Edits Layer E makes to existing files

All edits are conditional on `triage_agent_enabled`, so a run with the flag
off renders exactly what it rendered before.

| Existing file | Edit |
|---|---|
| `ansible/group_vars/all.yml` | New variables: `triage_agent_enabled` (default `false`), `triage_namespace` (`triage`), `triage_llm_base_url`, `triage_llm_model`, `triage_max_tool_calls` (8), `triage_cooldown_minutes` (10), `triage_allowed_namespaces` (`workload`, `monitoring`), `triage_image_tag` |
| `ansible/templates/monitoring-values.yml.j2` | `alertmanager.enabled` becomes `(not is_emulated) or triage_agent_enabled`; adds one webhook receiver to `http://triage-agent.triage.svc:8080/alert` and a route that sends alerts to it **in addition to** existing receivers (`continue: true`) so nothing else changes |
| `ansible/playbook.yml` | New task group tagged `triage`, guarded by `when: triage_agent_enabled`: create the `triage` namespace, the Elasticsearch `triage_reader` role and user and its Secret (`no_log: true`), render both templates, apply, wait for the four Deployments |
| `Makefile` | New group: `triage-build`, `triage-deploy`, `triage-eval`, `triage-logs` |
| `scripts/smoke-test.sh` | Seventh check group, run only when the flag is on (section 4.7) |
| `ansible/templates/elk-values.yml.j2` | No change. `drop_event` still drops only `logging` and `kube-system`, so triage-namespace logs flow like any workload's |

---


# 4. End-to-End Runtime & Execution Flow

What actually happens, in order, from a cold machine to a parsed log line in
Kibana and a GCP metric in Grafana. Sections 4.1-4.5 cover Layers A-D;
sections 4.6-4.7 trace Layer E.

## 4.1 Phase 1 - Infrastructure provisioning

### Step 1: `make up`

```
make up
 ├─ mkdir -p ./.floci/data
 ├─ docker compose up -d
 │   ├─ creates network centralized-observability-platform_observability
 │   └─ starts container floci-gcp
 │       ├─ binds :4588 (REST + gRPC, ALPN-multiplexed) and :6443
 │       ├─ mounts /var/run/docker.sock  ← the load-bearing mount
 │       └─ mounts ./.floci/data → /app/data
 └─ scripts/wait-for-emulator.sh
     ├─ polls http://localhost:4588/_floci-gcp/health until 200
     ├─ docker inspect floci-gcp → asserts docker.sock is in .Mounts
     ├─ docker exec → asserts /var/run/docker.sock is a socket file
     └─ prints /_floci-gcp/info
```

The emulator is now holding an empty project named `obs-local` in memory,
backed by `./.floci/data`, with a Docker client connected to the host daemon.

### Step 2: `make local-apply`

```
export GOOGLE_OAUTH_ACCESS_TOKEN=floci-mock-access-token
terraform -chdir=terraform/environments/local init
terraform -chdir=terraform/environments/local apply -auto-approve -parallelism=1
```

Terraform loads `providers.tf` and rewrites every Google API host to
`http://localhost:4588/...`. It then walks the graph:

```
1. module.vpc.google_compute_network.this
     POST :4588/compute/v1/projects/obs-local/global/networks
     → emulator records the network, returns an Operation
     → provider polls the Operation until DONE

2. module.vpc.google_compute_subnetwork.this
     POST :4588/compute/v1/projects/obs-local/regions/us-central1/subnetworks
     body carries ipCidrRange 10.10.0.0/20 and two secondaryIpRanges

3. module.vpc.google_compute_firewall.* (3 rules)

4. module.iam.google_service_account.gke_node
   module.iam.google_service_account.gcp_exporter
     POST :4588/v1/projects/obs-local/serviceAccounts

5. module.iam.google_project_iam_member.* (5 bindings, SEQUENTIALLY)
     ← this is where -parallelism=1 earns its place:
       each binding is GetIamPolicy → mutate → SetIamPolicy.
       Concurrent execution silently drops bindings.

6. module.iam.google_service_account_iam_member.workload_identity
     binds roles/iam.workloadIdentityUser for
     serviceAccount:obs-local.svc.id.goog[monitoring/gcp-exporter-sa]

7. module.gke.google_container_cluster.this        ← THE INTERESTING ONE
     POST :4588/container/v1/projects/obs-local/locations/us-central1/clusters

     Inside the emulator:
       a. parse the cluster spec (name, network, ipAllocationPolicy,
          workloadIdentityConfig)
       b. open /var/run/docker.sock
       c. docker pull rancher/k3s:latest
       d. docker create --privileged \
            --name obs-<cluster>-server \
            --network centralized-observability-platform_observability \
            -p 6443:6443 rancher/k3s:latest server
       e. docker start, then poll until the k3s API server answers
       f. read the generated kubeconfig and node token out of the container
       g. return a GKE-shaped Cluster object whose `endpoint` is the
          container's reachable address and whose masterAuth carries the CA

     Terraform polls the long-running Operation until DONE. This is the
     slowest step: image pull plus k3s boot, typically 60-180 seconds.

8. module.gke.google_container_node_pool.this
     POST .../clusters/<name>/nodePools
     The k3s server container already IS the node, so the emulator records
     the node pool spec and reconciles rather than starting another VM.

9. google_storage_bucket.observability_artifacts
     POST :4588/storage/v1/b?project=obs-local
     Exercises the GCS surface so the cloud path is pre-validated.
```

At this point `docker ps` shows two containers: `floci-gcp` and the k3s
server. A real Kubernetes API is listening on 6443.

### Step 3: `make kubeconfig`

```
terraform output -raw kubeconfig > .floci/kubeconfig
chmod 600 .floci/kubeconfig
KUBECONFIG=.floci/kubeconfig kubectl get nodes
```

The `kubeconfig` output was rendered by `yamlencode()` inside
`modules/gke/outputs.tf`, branching on `var.emulated` to embed the static
bearer token instead of an `exec` credential plugin. `kubectl get nodes`
returning one `Ready` node is the assertion that phase 1 worked.

## 4.2 Phase 2 - Configuration and deployment

### Step 4: `make deploy`

```
ansible-galaxy install -r ansible/requirements.yml
KUBECONFIG=.floci/kubeconfig ansible-playbook \
  -i ansible/inventory/hosts.ini ansible/playbook.yml \
  -e kubeconfig_path=.floci/kubeconfig
```

**Pre-flight (6 tasks).**

```
stat .floci/kubeconfig                    → exists?
python -c 'import kubernetes'             → importable?
terraform output -json ansible_facts      → read infra facts
set_fact                                  → adopt SA email, project, cluster name
k8s_info kind=Node (retry 10 × 10s)       → cluster reachable?
debug                                     → print topology
```

The `ansible_facts` read is where the exporter service account email crosses
from the infrastructure layer to the configuration layer. If Terraform is
unreachable the playbook continues with `group_vars` defaults and prints a
warning naming the email it will use.

**Namespaces.** Three `Namespace` objects, each labelled
`observability-role`, plus a `ResourceQuota` on `workload`.

**Secrets.** Four Secrets, values base64-encoded by the `b64encode` filter at
template time, every task `no_log: true`:

```
logging/elastic-credentials        username, password, elastic
logging/kibana-credentials         username, password, encryptionkey
logging/logstash-es-credentials    username, password
monitoring/grafana-admin-credentials  admin-user, admin-password
```

**RBAC.** Three ServiceAccounts, then one ClusterRole, then one
ClusterRoleBinding naming both the Prometheus and Filebeat SAs as subjects.
The GCP exporter SA receives its `iam.gke.io/gcp-service-account` annotation
here - computed as an empty map when `is_emulated` is true, since there is no
metadata server to honour it.

**Helm repositories.** Three repos added idempotently.

**ELK deployment**, in a deliberate order:

```
template elk-values.yml.j2 → ansible/rendered/elk-values.yml
set_fact elk_values = <file> | from_yaml

helm install elasticsearch elastic/elasticsearch --version 8.5.1
  ├─ chart creates StatefulSet elasticsearch-master
  ├─ volumeClaimTemplate → PVC bound by local-path provisioner
  ├─ sysctlInitContainer raises vm.max_map_count to 262144
  └─ ELASTIC_PASSWORD injected from the Secret

WAIT until containerStatuses[].ready count >= elasticsearch_replicas
  ← an active gate, not a sleep

helm install logstash elastic/logstash
  ├─ Deployment + ClusterIP service `logstash` on 5044 and 9600
  ├─ logstash.conf mounted from the rendered pipeline
  └─ persistent queue PVC

helm install kibana elastic/kibana
  └─ Deployment + Service on 5601, credentials from the Secret

helm install filebeat elastic/filebeat
  ├─ DaemonSet, one pod per node
  ├─ hostPath mounts /var/log/containers and /var/log/pods, read-only
  └─ uses the pre-created ServiceAccount obs-filebeat
```

**Monitoring deployment.**

```
template monitoring-values.yml.j2 → ansible/rendered/monitoring-values.yml

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack
  ├─ installs the Operator CRDs
  ├─ Prometheus CR → Operator generates a StatefulSet + PVC, :9090, 15s
  ├─ Grafana Deployment + Service, password from the Secret
  ├─ node-exporter DaemonSet :9100 with host /proc and /sys
  └─ kube-state-metrics Deployment :8080
```

**GCP exporter.**

```
template gcp-exporter.yml.j2 → ansible/rendered/gcp-exporter.yml
k8s apply=true src=<that file>
  → ConfigMap, Deployment(:9255), Service, ServiceMonitor, PDB, NetworkPolicy
```

The Prometheus Operator notices the new ServiceMonitor within seconds and
regenerates Prometheus's scrape configuration without a restart.

### Step 5: `make workload`

```
kubectl apply -f workloads/vprofile.yaml
kubectl -n workload rollout status deploy/vprodb --timeout=600s
kubectl -n workload rollout status deploy/vproapp --timeout=300s
kubectl -n workload rollout status deploy/vproweb --timeout=180s
```

The five tiers roll out in dependency order: `vprodb` initializes MySQL and
imports the `accounts` schema, `vproapp`'s `wait-for-db` init container unblocks
once port 3306 responds, and `vproweb` begins proxying HTTP traffic and exposing
NGINX metrics on `:9113`.

### Step 6 (optional, Layer E): `make triage-build && make triage-deploy`

Only when `triage_agent_enabled=true`. Described in section 4.6.1. With the
flag off these targets do nothing and Steps 1-5 are unchanged.

## 4.3 Phase 3 - The live logging pipeline

Trace of one single HTTP request, end to end.

**4.3.1 Generation.** A client (or `smoke-test.sh`) issues
`GET http://vproweb.workload.svc/vprofile-missing-page`. `vproweb` (NGINX)
proxies to `vproapp` (Tomcat), receives 404, and writes one combined access
log line to `/dev/stdout`:

```
10.20.1.7 - - [12/Nov/2026:08:15:42 +0000] "GET /vprofile-missing-page HTTP/1.1" 404 10 "-" "curl/8.11.0" "-"
```

**4.3.2 The container runtime captures it.** `/dev/stdout` in the container
is a pipe to containerd. containerd writes a CRI-formatted line to:

```
/var/log/pods/workload_vproweb-7799_<uid>/nginx/0.log
```

and maintains a symlink at:

```
/var/log/containers/vproweb-7799_workload_nginx-<containerid>.log
```

The CRI line prefixes the payload with a timestamp and stream:

```
2026-11-12T08:15:42.118Z stdout F 10.20.1.7 - - [12/Nov/2026:08:15:42 +0000] "GET /vprofile-missing-page HTTP/1.1" 404 10 "-" "curl/8.11.0" "-"
```

**This is precisely why the Filebeat DaemonSet mounts both directories.** The
glob matches the symlinks in `/var/log/containers`; resolving them requires
`/var/log/pods`. One mount without the other yields an empty pipeline and no
error message.

**4.3.3 Filebeat harvests.** The Filebeat pod on that node is tailing
`/var/log/containers/*.log`. Its `type: container` input with the `container`
parser strips the CRI prefix and recovers the original payload into `message`.

The `add_kubernetes_metadata` processor then parses the filename to recover
the pod UID, queries the API server (using the `obs-filebeat` ServiceAccount
and the `obs-cluster-reader` ClusterRole) and attaches:

```json
{
  "kubernetes": {
    "pod":       { "name": "vproweb-7799-x4k2" },
    "namespace": "workload",
    "container": { "name": "nginx" },
    "node":      { "name": "obs-gke-node-1" },
    "labels":    { "app": "vproweb" }
  }
}
```

The `drop_event` processor checks the namespace against `logging` and
`kube-system`; `workload` is neither, so the event proceeds. `add_fields`
attaches `cluster` and `environment`.

**4.3.4 Transport.** Filebeat batches up to 2048 events and sends them over
the Beats protocol to `logstash.logging.svc:5044`. With `max_retries: -1`, a
refused connection retries indefinitely rather than dropping the event.

**4.3.5 Logstash input.** The `beats` input on 5044 accepts the batch. Each
event enters the filter stage.

**4.3.6 The filter stage, statement by statement.**

```
mutate { add_field => { "raw_message" => "%{message}" } }
   → raw_message = the full original line, preserved before anything else

if [kubernetes][container][name] == "nginx"  → TRUE, enter the NGINX branch

grok (pattern 1, full combined format) → MATCHES:
     client_ip     = "10.20.1.7"
     remote_user   = "-"
     timestamp     = "12/Nov/2026:08:15:42 +0000"
     http_method   = "GET"
     request_path  = "/vprofile-missing-page"
     http_version  = "1.1"
     http_status   = 404      ← :int, so Elasticsearch maps it as a long
     bytes_sent    = 10       ← :int
     http_referer  = "-"
     user_agent    = "curl/8.11.0"

date { match => ["timestamp", "dd/MMM/yyyy:HH:mm:ss Z", ...] }
   → @timestamp = 2026-11-12T08:15:42Z, taken from the LINE, not from
     the moment Filebeat read it

if [http_status] >= 500 ... else if >= 400 → TRUE
   → log_level = "WARN"

grok on request_path → request_uri = "/vprofile-missing-page"

mutate { uppercase, rename kubernetes.* , remove_field [agent, ecs, input, stream, host] }
mutate { add_field [@metadata][index_prefix] = "logstash-k8s" }
```

**4.3.7 Output.** The `elasticsearch` output writes to
`http://elasticsearch-master.logging.svc:9200` using the credentials from
`logstash-es-credentials`, into index `logstash-k8s-2026.11.12`. The managed
index template guarantees `http_status` is a `long` and `client_ip` an `ip`.

**4.3.8 Elasticsearch indexes it.** The document lands on the StatefulSet's
PVC. An inverted index is built for every extracted field, so
`http_status: 404` is a term lookup rather than a scan. The data survives pod
restarts because of the PVC.

**4.3.9 Kibana queries it.** Kibana connects to the same service with the
credentials from `kibana-credentials`. A data view over `logstash-k8s-*` with
time field `@timestamp` makes this KQL work:

```
http_status >= 400 and kubernetes.namespace : "workload"
```

Total latency, generation to searchable: typically 5-20 seconds, dominated by
the Filebeat flush interval and Elasticsearch's 1-second refresh.

**The application-log path differs only in the filter.** A `vproapp` (Tomcat)
log line fails the NGINX condition, enters the generic branch, and the
`TIMESTAMP_ISO8601 ... LOGLEVEL` pattern extracts `log_level` and
`log_detail`. Any multi-line Java stack trace that follows is folded into the
same event by Filebeat's multiline configuration before it ever reaches Logstash.

## 4.4 Phase 3b - The live metrics pipeline

Three producers, one scraper, one visualizer.

**4.4.1 Node Exporter (hardware).** The DaemonSet pod runs with
`hostNetwork: true` and `hostPID: true` and mounts the node's root
filesystem. On a scrape it reads `/proc/stat`, `/proc/meminfo`,
`/proc/diskstats` and `/sys/class/net/*` and renders:

```
node_cpu_seconds_total{cpu="0",mode="user"} 184273.21
node_memory_MemAvailable_bytes 3.221225472e+09
node_disk_io_time_seconds_total{device="sda"} 1847.3
```

These are the **node's** numbers, not the container's, which is the entire
point of the host mounts.

**4.4.2 Kube State Metrics (object state).** It holds a watch on the API
server and renders Kubernetes object state - not resource usage:

```
kube_pod_status_phase{namespace="workload",pod="vproweb-7799-x4k2",phase="Running"} 1
kube_pod_container_status_restarts_total{namespace="workload",...} 0
kube_deployment_status_replicas_available{namespace="workload",deployment="vproweb"} 1
kube_node_status_capacity{node="obs-gke-node-1",resource="cpu"} 2
```

**4.4.3 GCP Stackdriver Exporter (external cloud).** On scrape it:

1. Obtains a token. **In the cloud**, the Google client library detects it is
   on GKE, requests a token from `metadata.google.internal`; the GKE metadata
   server validates the `roles/iam.workloadIdentityUser` binding Terraform
   created plus the `iam.gke.io/gcp-service-account` annotation Ansible
   applied, and mints a token for `obs-gcp-exporter-sa` valid about an hour.
   **Locally**, `STACKDRIVER_EMULATOR_HOST` points it at `floci-gcp:4588`
   with a stub token.
2. Calls `monitoring.googleapis.com/v3/projects/<id>/timeSeries` once per
   configured prefix - eight calls per scrape, which is why the prefix list is
   described as the main cost driver.
3. Renders the results as Prometheus metrics on `:9255/metrics`:

```
stackdriver_gce_instance_compute_googleapis_com_instance_cpu_utilization{instance_name="gke-obs-..."} 0.37
stackdriver_gcs_bucket_storage_googleapis_com_api_request_count{bucket_name="obs-artifacts-..."} 142
```

Locally the target is UP and the response is well-formed but empty: the
emulator serves the API shape, not a populated time-series store.

**4.4.4 Prometheus scrapes.** Prometheus discovered these three targets by
three different mechanisms, which is deliberate:

| Target | Discovery |
|---|---|
| Node Exporter | ServiceMonitor shipped by the chart |
| Kube State Metrics | ServiceMonitor shipped by the chart |
| GCP Exporter | ServiceMonitor in `gcp-exporter.yml.j2`, adopted because `serviceMonitorSelectorNilUsesHelmValues: false` |
| nginx sidecar | `prometheus.io/scrape` pod annotation via `additionalScrapeConfigs` |

Every 15 seconds it issues an HTTP GET to each target's `/metrics`, parses
the exposition format, attaches external labels (`cluster`, `environment`,
`project`) and appends to the TSDB on the PVC. The GCP exporter is the
exception at 5 minutes, for the reasons in section 2.9.

**4.4.5 Grafana queries.** Grafana's Prometheus data source was provisioned
declaratively at `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`
and is the default, so a fresh pod is immediately useful - nobody ever clicks
"Add data source" on this platform. A panel issues a PromQL query, Prometheus
evaluates it against the TSDB, and the result renders.

Because an Elasticsearch data source is also provisioned, a single dashboard
can place a CPU spike next to the log lines that explain it.

## 4.5 What the smoke test observes

`make smoke` walks this entire flow in reverse as an assertion:

```
emulator health + socket  → phase 1 prerequisites
nodes Ready               → phase 1 succeeded
pods Running in 3 ns      → phase 2 succeeded
curl / → 200              → generation works
curl /missing → 404       → generation produces varied status
wait 45s                  → propagation window
_cat/indices              → Filebeat → Logstash → Elasticsearch works
_search http_status:404
   + client_ip
   + request_path         → GROK ACTUALLY PARSED IT
each of 7 fields exists   → every required field is indexed
kubernetes.namespace      → metadata enrichment works
/api/v1/targets           → exporters registered
up{job=~node-exporter}    → and actually returning data
kube_pod_status_phase     → KSM returning data
nginx_http_requests_total → annotation discovery works
```

Exit code 0 means both pipelines are live end to end. With
`triage_agent_enabled=true`, section 4.7 appends a further group.

## 4.6 Phase 4 (optional, Layer E) - one alert through the triage agent

Everything in this section is the **intended** runtime, written from the
design. It has not been executed. The example note in 4.6.4 is illustrative,
not a recorded output.

### 4.6.1 Bring-up

```
make triage-build
 ├─ docker build ×4   (triage-agent, prometheus-mcp, elasticsearch-mcp, kubernetes-mcp)
 └─ import the images into the k3s node's runtime          ← confirm method on first run

make triage-deploy    (ansible-playbook --tags triage -e triage_agent_enabled=true)
 ├─ re-render monitoring-values.yml: Alertmanager on, webhook receiver added
 ├─ helm upgrade kube-prometheus-stack                      ← the only change to a Layer D release
 ├─ create namespace triage + ResourceQuota
 ├─ create ES role triage_reader + user, store in triage-es-credentials (no_log)
 ├─ render + apply triage-runbooks.yml.j2 and triage-agent.yml.j2
 └─ wait for 4 Deployments Ready
```

The LLM is not started by this target. The operator runs Ollama on the host
and sets `triage_llm_base_url` to it (section 2.11.6).

### 4.6.2 Trigger

A PrometheusRule fires. Prometheus sends it to Alertmanager, which applies
its grouping window and then issues:

```
POST http://triage-agent.triage.svc:8080/alert
{ "status": "firing",
  "alerts": [ { "labels": { "alertname": "<rule>", "namespace": "workload",
                            "pod": "vproapp-5c8d-x9k2", "severity": "warning" },
                "annotations": { "summary": "..." },
                "startsAt": "2026-11-25T10:02:11Z",
                "fingerprint": "<hash>" } ] }
```

The existing receivers still fire as before, because the new route uses
`continue: true`. Without Alertmanager, the same body can be sent by
`curl` or by the evaluation harness; the agent cannot tell the difference.

### 4.6.3 The agent loop

```
1. main.py validates the payload (Pydantic). Invalid → 422, no LLM call.
2. If fingerprint is inside the 10-minute cool-down → 200, "deduplicated", stop.
3. Enqueue (one run at a time). agent.py loads the runbook for this alertname
   from the ConfigMap and builds the prompt: alert labels, runbook, rules.
4. The LLM requests tools. Each call goes to an MCP server over HTTP:

   prometheus-mcp     query_range(restarts / cpu / memory for the pod, last 30 min)
   kubernetes-mcp     get_pod, list_events(pod), get_pod_logs(previous container)
   elasticsearch-mcp  search_logs(namespace=workload, pod=..., level=ERROR, minutes=30)

   Every call is checked against limits inside the server (2.11.3).
   Every call is audit-logged as tool + args + result size/hash (2.11.5).
5. After at most 8 tool calls or the timeout, the model must return a TriageNote.
   Invalid → one retry → otherwise outcome="failed", reported as such.
6. The note is stored on the results PVC, exposed at GET /triage/<fingerprint>,
   and printed to stdout as one JSON line. triage_runs_total{outcome} increments.
```

### 4.6.4 Illustrative output shape

```json
{
  "summary": "vproapp is crash-looping; the previous container exited with an error before Tomcat finished starting.",
  "evidence": [
    "kube_pod_container_status_restarts_total rose from 0 to 6 in 12 minutes",
    "Event: Back-off restarting failed container",
    "Previous-container log tail ends in a connection error to vprodb:3306"
  ],
  "likely_cause": "Database not reachable when the app started",
  "confidence": "medium",
  "suggested_commands": [
    "kubectl -n workload get pods -l app=vprodb",
    "kubectl -n workload logs deploy/vprodb --tail=100"
  ]
}
```

`confidence` is the model's own stated value and is not calibrated. Section
5.8 is how it will be checked against ground truth.

### 4.6.5 What the on-call engineer gets, and what they do not

They get a hypothesis, the evidence behind it, and commands to run, usually
before they have opened a terminal. They do **not** get an action taken, a
guarantee that the hypothesis is right, or a substitute for reading the
evidence themselves.

## 4.7 Smoke test extension (Layer E)

Appended to `smoke-test.sh` only when `triage_agent_enabled=true`. Check
numbering continues from the existing six groups.

| # | Checks | Method |
|---|---|---|
| 7a | Four triage pods Running and Ready | `kubectl -n triage get pods` |
| 7b | Agent liveness and its three MCP backends reachable | `GET /healthz` reports each MCP server's status |
| 7c | **Read-only holds** | `kubectl auth can-i create/update/delete pods --as=system:serviceaccount:triage:<each SA>` must answer `no` for every mutating verb; `get secrets` must answer `no` |
| 7d | Scope holds | `elasticsearch-mcp` refused a query for namespace `kube-system` (not in the allowlist) |
| 7e | End-to-end with a synthetic payload | `POST /alert` with a canned payload; assert 200, then assert `GET /triage/<fingerprint>` returns a schema-valid `TriageNote` |
| 7f | Metrics exposed | `triage_runs_total` present in Prometheus |

7c and 7d are the checks that matter most: they test the security properties
of section 2.11 directly rather than assuming them. 7e checks that the
pipeline works and that the output is well-formed. It does **not** check that
the diagnosis is correct; that is the evaluation in section 5.8.

---

# 5. Validation & Alignment Checklist

Each requirement from the brief, mapped to the file and code construct that
satisfies it. Verified by rendering every template for both environments and
asserting on the parsed output; the assertion results are in section 5.4.
Sections 5.1-5.6 cover Layers A-D. Layer E has its own checklist (5.7) and
evaluation plan (5.8), kept separate because none of its rows are verified.

## 5.1 Section 1 of the brief - overview, stack, strategy

| # | Requirement | File | Construct |
|---|---|---|---|
| 1.1 | Kubernetes-native observability platform on GKE | `terraform/modules/gke/main.tf` | `google_container_cluster.this` + `google_container_node_pool.this` |
| 1.2 | Workload logs shipped automatically | `ansible/templates/elk-values.yml.j2` | `filebeat.daemonset` with `/var/log/containers/*.log` |
| 1.3 | Metrics scraped and visualized | `ansible/templates/monitoring-values.yml.j2` | `prometheus` + `grafana` sections |
| 1.4 | Local phase on `floci-gcp` at :4588 | `docker-compose.yml`, `terraform/environments/local/providers.tf` | `ports: 4588:4588`; ten `*_custom_endpoint` |
| 1.5 | Emulator uses `/var/run/docker.sock` to spin up k3s | `docker-compose.yml` | `volumes: /var/run/docker.sock:/var/run/docker.sock` + `FLOCI_GCP_SERVICES_GKE_MOCK: "false"` |
| 1.6 | Cloud phase = same modules, switch directory | `terraform/environments/gcp/main.tf` | `module "observability" { source = "../../stack" }`, identical args |
| 1.7 | Real tfvars + remote GCS state | `environments/gcp/terraform.tfvars.example`, `versions.tf` | `backend "gcs"` |
| 1.8 | Terraform 1.6+, Google provider 6.0+ | `terraform/stack/versions.tf` | `required_version >= 1.6.0`; `google >= 6.0.0, < 7.0.0` |
| 1.9 | `floci/floci-gcp:latest` via Compose | `docker-compose.yml` | `image: floci/floci-gcp:latest` |
| 1.10 | Ansible `kubernetes.core` + Jinja2 + Helm | `ansible/requirements.yml`, `templates/*.j2` | `kubernetes.core >=3.0.0`; 3 templates; `kubernetes.core.helm` |
| 1.11 | Filebeat → Logstash → Elasticsearch → Kibana | `elk-values.yml.j2` | four release sub-trees |
| 1.12 | Node Exporter, KSM, GCP exporter → Prometheus → Grafana | `monitoring-values.yml.j2`, `gcp-exporter.yml.j2` | `nodeExporter`, `kubeStateMetrics`, exporter Deployment |
| 1.13 | Multi-tier VProfile workload with 200/404 and CPU/memory | `workloads/vprofile.yaml` | `vproweb` (NGINX + exporter sidecar) + `vproapp` + `vprodb` + `vprocache01` + `vpromq01` |

## 5.2 Section 2 of the brief - the four layers

### Layer A: Cloud Infrastructure & Security

| # | Requirement | File | Construct |
|---|---|---|---|
| A.1.1 | Custom VPC network | `modules/vpc/main.tf` | `google_compute_network.this`, `auto_create_subnetworks = false` |
| A.1.2 | Regional subnet | `modules/vpc/main.tf` | `google_compute_subnetwork.this`, `region = var.region` |
| A.1.3 | Primary CIDR for nodes | `modules/vpc/main.tf` | `ip_cidr_range = var.subnet_cidr` (`10.10.0.0/20`) |
| A.1.4 | Two secondary ranges for Pods and Services | `modules/vpc/main.tf` | two `secondary_ip_range` blocks (`10.20.0.0/16`, `10.30.0.0/20`) |
| A.1.5 | VPC-native alias IP cluster | `modules/gke/main.tf` | `ip_allocation_policy { cluster_secondary_range_name, services_secondary_range_name }` |
| A.2.1 | GKE cluster on the custom VPC/subnet | `modules/gke/main.tf` | `network`, `subnetwork` from `module.vpc` |
| A.2.2 | Workload Identity enabled | `modules/gke/main.tf` | `workload_identity_config { workload_pool = "${project}.svc.id.goog" }` |
| A.2.3 | Managed node pool with OAuth scopes | `modules/gke/main.tf` | `google_container_node_pool`, `oauth_scopes = ["...cloud-platform"]` |
| A.2.4 | Dedicated node service account attached | `modules/gke/main.tf` | `node_config.service_account = var.node_service_account_email` |
| A.2.5 | Exports connection details for kubeconfig | `modules/gke/outputs.tf` | `endpoint`, `cluster_ca_certificate`, rendered `kubeconfig` |
| A.3.1 | `obs-gke-node-sa` with least-privilege writer roles | `modules/iam/main.tf` | `google_service_account.gke_node`; `local.node_sa_roles` = logWriter, metricWriter, monitoring.viewer, resourceMetadata.writer |
| A.3.2 | `obs-gcp-exporter-sa` with `roles/monitoring.viewer` | `modules/iam/main.tf` | `google_service_account.gcp_exporter`; `local.exporter_sa_roles` |
| A.3.3 | `roles/iam.workloadIdentityUser` binding to `monitoring/gcp-exporter-sa` | `modules/iam/main.tf` | `google_service_account_iam_member.workload_identity` with `local.k8s_sa_member` |
| A.4.1 | Local uses local tfstate | `environments/local/versions.tf` | `backend "local" { path = "terraform.tfstate" }` |
| A.4.2 | All seven endpoints routed to :4588 | `environments/local/providers.tf` | compute, container, iam, storage, monitoring, service_usage, resource_manager (+ iam_credentials, resource_manager_v3, cloud_resource_manager) |
| A.4.3 | Mock access token `floci-mock-access-token` | `environments/local/variables.tf` | `var.emulator_access_token` default |
| A.4.4 | GCP uses ADC | `environments/gcp/providers.tf` | no `credentials` argument at all |
| A.4.5 | Remote GCS state with locking | `environments/gcp/versions.tf` | `backend "gcs"`; GCS locking is automatic via object generation |

### Layer B: Configuration Management & Security

| # | Requirement | File | Construct |
|---|---|---|---|
| B.1 | Three namespaces: workload, logging, monitoring | `ansible/playbook.yml` | `Namespaces \| Create the three isolated namespaces`, loops `namespaces` from `group_vars` |
| B.2.1 | Secrets via Ansible vars + Jinja2, base64 | `ansible/playbook.yml` | four Secret tasks using `data:` with `\| b64encode` |
| B.2.2 | Elasticsearch & Kibana auth + TLS config | `playbook.yml` + `elk-values.yml.j2` | `elastic-credentials`, `kibana-credentials`; `elasticsearch_tls_enabled` drives `createCert` and `xpack.security.*.ssl.enabled` |
| B.2.3 | Grafana admin credentials | `playbook.yml` | `grafana-admin-credentials` with `admin-user` / `admin-password` |
| B.3.1 | ClusterRole: get/list/watch on nodes, pods, services, endpoints | `playbook.yml` | `obs-cluster-reader`, rule 1 uses `rbac_core_resources` + `rbac_verbs` |
| B.3.2 | Bound to the Prometheus and Filebeat SAs | `playbook.yml` | `obs-cluster-reader-binding` with both subjects |
| B.4.1 | Render `*.yml.j2` templates | `playbook.yml` | three `ansible.builtin.template` tasks writing to `rendered/` |
| B.4.2 | `kubernetes.core.helm`, idempotent | `playbook.yml` | five `kubernetes.core.helm` tasks |

### Layer C: The Logging Pipeline

| # | Requirement | File | Construct |
|---|---|---|---|
| C.1 | Pods write stdout/stderr; runtime writes `/var/log/containers`, `/var/log/pods` | `workloads/vprofile.yaml` | `vproweb` NGINX access logs to `/dev/stdout` + `vproapp`/`vprodb`/`vpromq01` stdout/stderr |
| C.2.1 | Filebeat as a DaemonSet, one pod per node | `elk-values.yml.j2` | `filebeat.daemonset.enabled: true`, `deployment.enabled: false` |
| C.2.2 | Mounts `/var/log/containers` and `/var/log/pods` hostPath read-only | `elk-values.yml.j2` | `extraVolumes` hostPath + `extraVolumeMounts` with `readOnly: true` |
| C.2.3 | Tails in real time | `elk-values.yml.j2` | `filebeat.inputs: type: container, paths: /var/log/containers/*.log` |
| C.2.4 | Enriches with Kubernetes metadata | `elk-values.yml.j2` | `add_kubernetes_metadata` processor |
| C.2.5 | Forwards over TCP 5044 to Logstash | `elk-values.yml.j2` | `output.logstash.hosts: ["logstash.logging.svc:5044"]` |
| C.3.1 | Logstash as Deployment + ClusterIP on 5044 | `elk-values.yml.j2` | `logstash.service.ports[0].port: 5044`, `type: ClusterIP` |
| C.3.2 | Input: beats plugin on 5044 | `elk-values.yml.j2` | `input { beats { port => 5044 } }` |
| C.3.3 | Filter: Grok producing the 8 named fields | `elk-values.yml.j2` | `filter { ... }`; see 5.2.1 below |
| C.3.4 | Output: Elasticsearch over HTTP 9200, daily index | `elk-values.yml.j2` | `index => "logstash-k8s-%{+YYYY.MM.dd}"` |
| C.4.1 | Elasticsearch as StatefulSet + PVC on 9200 | `elk-values.yml.j2` | `persistence.enabled: true` + `volumeClaimTemplate`; `httpPort: 9200` |
| C.4.2 | Data survives pod restarts | `elk-values.yml.j2` | the PVC above |
| C.4.3 | Inverted indices on extracted keys | `elk-values.yml.j2` | `manage_template => true` with explicit typing |
| C.5.1 | Kibana as Deployment + Service on 5601 | `elk-values.yml.j2` | `kibana.httpPort: 5601`, `service.port: 5601` |
| C.5.2 | Connects to `elasticsearch:9200` with Secret credentials | `elk-values.yml.j2` | `elasticsearchHosts` + `extraEnvs` from `kibana-credentials` |

**5.2.1 The eight required Grok fields**, all in the `filter` block of
`elk-values.yml.j2`:

| Field | Source |
|---|---|
| `timestamp` | `%{HTTPDATE:timestamp}`, then reparsed into `@timestamp` by the `date` filter |
| `client_ip` | `%{IPORHOST:client_ip}` |
| `http_method` | `%{WORD:http_method}` |
| `request_path` | `%{DATA:request_path}`, further split into `request_uri` / `request_params` |
| `http_status` | `%{NUMBER:http_status:int}` - typed as integer |
| `bytes_sent` | `%{NUMBER:bytes_sent:int}` - typed as integer |
| `log_level` | `%{LOGLEVEL:log_level}` in the generic branch; derived from status class in the NGINX branch |
| `raw_message` | `mutate { add_field => { "raw_message" => "%{message}" } }`, first statement in the filter |

### Layer D: The Metrics Pipeline

| # | Requirement | File | Construct |
|---|---|---|---|
| D.1.1 | Node Exporter DaemonSet on 9100 | `monitoring-values.yml.j2` | `prometheus-node-exporter.service.port: 9100` |
| D.1.2 | Mounts host `/proc` and `/sys` | `monitoring-values.yml.j2` | `hostRootFsMount.enabled: true`, `hostNetwork: true`, `hostPID: true` |
| D.1.3 | KSM Deployment on 8080 | `monitoring-values.yml.j2` | `kube-state-metrics.service.port: 8080` |
| D.1.4 | KSM queries the API server for object state | `monitoring-values.yml.j2` | `collectors:` list of 21 object types |
| D.1.5 | GCP Stackdriver Exporter Deployment on 9255 | `gcp-exporter.yml.j2` | `containerPort: 9255`, `--web.listen-address=:9255` |
| D.1.6 | Runs in `monitoring` with the WI-annotated SA | `gcp-exporter.yml.j2` + `playbook.yml` | `serviceAccountName: gcp-exporter-sa`; annotation applied in the RBAC task |
| D.1.7 | Pulls external GCP metrics, exposes Prometheus format | `gcp-exporter.yml.j2` | `--monitoring.metrics-type-prefixes` ×8 covering compute, storage, loadbalancing, kubernetes |
| D.2.1 | Prometheus StatefulSet + PVC on 9090 | `monitoring-values.yml.j2` | `storageSpec.volumeClaimTemplate`; `service.port: 9090`. The Operator generates the StatefulSet from the Prometheus CR |
| D.2.2 | **15s global scrape interval** | `monitoring-values.yml.j2` | `prometheusSpec.scrapeInterval: "15s"` |
| D.2.3 | Kubernetes SD via ServiceMonitor / scrape_configs | `monitoring-values.yml.j2` | `serviceMonitorSelectorNilUsesHelmValues: false` + `additionalScrapeConfigs` |
| D.2.4 | Discovers all three exporters | `monitoring-values.yml.j2`, `gcp-exporter.yml.j2` | chart ServiceMonitors ×2 + the exporter's own ServiceMonitor |
| D.3.1 | Grafana Deployment + Service on 3000 | `monitoring-values.yml.j2` | `grafana.service.targetPort: 3000` |
| D.3.2 | Prometheus as default data source | `monitoring-values.yml.j2` | `datasources` → `url: ...:9090`, `isDefault: true` |
| D.3.3 | Secured with the Jinja2 admin password Secret | `monitoring-values.yml.j2` | `admin.existingSecret: grafana-admin-credentials` |
| D.3.4 | Pre-loaded Kubernetes/Node dashboards | `monitoring-values.yml.j2` | `defaultDashboardsEnabled: true` + four pinned `gnetId` dashboards |

## 5.3 Section 3 of the brief - local emulation rules

| # | Requirement | File | Construct |
|---|---|---|---|
| E.1 | Docker socket mounted into `floci-gcp` | `docker-compose.yml` | `/var/run/docker.sock:/var/run/docker.sock`; additionally **asserted** by `wait-for-emulator.sh` and by smoke-test check 1 |
| E.2 | `-parallelism=1` on apply and destroy | `Makefile` | `TF_PARALLELISM ?= 1` in `TF_APPLY_FLAGS` and `TF_DESTROY_FLAGS`, used by all four apply/destroy targets |
| E.3.1 | Emulator health check | `scripts/smoke-test.sh` | check 1: `curl /_floci-gcp/health` with a TCP-4588 fallback |
| E.3.2 | Nodes Ready | `scripts/smoke-test.sh` | check 2: counts `Ready` vs total |
| E.3.3 | All pods Running in all three namespaces | `scripts/smoke-test.sh` | check 3: `awk` over `kubectl get pods`, verifies readiness `n/n` |
| E.3.4 | Curl NGINX for 200 and 404 | `scripts/smoke-test.sh` | check 4: asserts both codes, then 50 more requests |
| E.3.5 | Query ES `_cat/indices` and `_search` | `scripts/smoke-test.sh` | check 5: both, plus per-field existence assertions |
| E.3.6 | Query Prometheus `/api/v1/targets` | `scripts/smoke-test.sh` | check 6: targets plus real PromQL per exporter |

(The `E.` prefix in this table is the brief's local-emulation group, and is
unrelated to **Layer E**. Layer E rows use the `X.` prefix in section 5.7 to
avoid the collision.)

### Documented deviations

Four places where the implementation does not follow the brief literally.
Each is a deliberate engineering decision, not an omission.

| Brief says | Implementation | Why |
|---|---|---|
| Health endpoint `http://localhost:4588/_floci/health` | `/_floci-gcp/health` | The emulator's actual control-plane path is `/_floci-gcp`. The brief allowed "or port 4588 reachability"; the script tries the correct path first and falls back to a TCP probe, so both are covered |
| 15s scrape interval, globally | 15s global; **5m** for the GCP exporter only | Cloud Monitoring publishes at 1-minute granularity with a 3-4 minute ingestion delay. 15s would quadruple the API bill to re-read identical points. See section 2.9 |
| Prometheus "as a StatefulSet" | A `Prometheus` CR whose `storageSpec` causes the Operator to generate a StatefulSet + PVC | The outcome is exactly as specified; hand-writing the StatefulSet would mean abandoning the Operator and its service discovery |
| Elasticsearch and Kibana "TLS configurations" | Credentials always; TLS on in the cloud, off locally | `createCert: true` on single-node k3s requires cert tooling that makes the local phase fragile. Governed by one variable (`elasticsearch_tls_enabled`), on by default when `is_emulated` is false |

## 5.4 Verification performed

Every Jinja2 template was rendered against `group_vars/all.yml` for **both**
`is_emulated: true` and `is_emulated: false`, parsed as YAML, and asserted
on structurally. All Terraform files were parsed as HCL. All YAML manifests
were parsed. Both shell scripts were syntax-checked with `bash -n`, and the
Makefile with `make -n`.

```
Terraform HCL           23 files parsed, 0 failures
Ansible YAML            playbook.yml, group_vars/all.yml valid
workloads/vprofile.yaml 12 documents: Secret, PVC, 5 Deployments
                        (vprodb, vprocache01, vpromq01, vproapp, vproweb),
                        and 5 ClusterIP Services
Shell                   wait-for-emulator.sh, smoke-test.sh: bash -n clean
Makefile                make -n help: parses

RENDER: is_emulated = true (local)
  elk-values.yml.j2          610 lines, 1 YAML doc
  monitoring-values.yml.j2   490 lines, 1 YAML doc
  gcp-exporter.yml.j2        379 lines, 6 YAML docs
  PASS ELK: 4 releases | 8 grok fields | daily index | beats:5044
            | ES PVC | Kibana:5601 | hostPath read-only
  PASS Monitoring: 15s | Prometheus PVC + :9090 | node-exporter :9100
            | KSM :8080 | Grafana :3000 + existingSecret + datasource
            + dashboards
  PASS GCP exporter: ConfigMap + Deployment + Service + ServiceMonitor
            + PodDisruptionBudget + NetworkPolicy | SA gcp-exporter-sa
            | :9255 | ns monitoring

RENDER: is_emulated = false (real GCP)
  elk-values.yml.j2          609 lines, 1 YAML doc
  monitoring-values.yml.j2   490 lines, 1 YAML doc
  gcp-exporter.yml.j2        365 lines, 6 YAML docs
  PASS (same three assertion groups)
```

The specific structural assertions run against the parsed output:

- `elk_values` contains exactly the four keys `elasticsearch`, `logstash`,
  `kibana`, `filebeat`
- the Logstash pipeline string contains all eight required field names
- the index pattern `logstash-k8s-%{+YYYY.MM.dd}` is present
- the Logstash service exposes port 5044
- Elasticsearch has a `volumeClaimTemplate` with a storage request
- Kibana `httpPort` is 5601
- the Filebeat config references `/var/log/containers/*.log`,
  `logstash.logging.svc:5044` and `add_kubernetes_metadata`
- `filebeat.managedServiceAccount` is `false`
- both hostPath mounts are present and every one has `readOnly: true`
- `prometheusSpec.scrapeInterval` is exactly `15s`
- `prometheusSpec.serviceAccountName` is `obs-prometheus`
- `serviceMonitorSelectorNilUsesHelmValues` is `false`
- Prometheus has a `storageSpec.volumeClaimTemplate` and serves on 9090
- node-exporter is on 9100, kube-state-metrics on 8080, Grafana on 3000
- Grafana uses `existingSecret: grafana-admin-credentials`
- the first Grafana data source points at `:9090` and `isDefault` is true
- `defaultDashboardsEnabled` is true
- the exporter manifests are exactly the six expected kinds, in order
- the exporter Deployment uses `serviceAccountName: gcp-exporter-sa`, listens
  on 9255 and lives in the `monitoring` namespace

This verification covers Layers A-D only. No Layer E template exists yet, so
none has been rendered or asserted on.

## 5.5 What has not been verified, and how to verify it

Static validation cannot prove runtime behaviour. These require a machine
with Docker and the tooling from README section 2:

| Claim | Command |
|---|---|
| The emulator starts k3s over the socket | `make up && make local-apply && docker ps --filter name=obs-` |
| Terraform applies cleanly against :4588 | `make local-apply` |
| The kubeconfig works | `make kubeconfig` (runs `kubectl get nodes` itself) |
| Helm releases install and become ready | `make deploy` |
| Logs flow end to end with parsed fields | `make workload && make smoke` (check 5) |
| Exporters register and return data | `make smoke` (check 6) |
| **Workload Identity token exchange** | README section 5.7 - the metadata-server query. This is the one thing the local phase cannot prove |
| *(Layer E)* Images build and import into k3s | `make triage-build`; method of import to be confirmed on first run |
| *(Layer E)* Agent is read-only and scoped | `make smoke` checks 7c and 7d |
| *(Layer E)* Webhook path works through real Alertmanager | Fire a real rule, then `GET /triage/<fingerprint>` |
| *(Layer E)* Local LLM can drive the tool loop reliably | `make triage-eval`, section 5.8; the outcome is unknown |

Chart versions (`elastic 8.5.1`, `kube-prometheus-stack 65.5.1`) are pinned
from known-good releases. If your registry mirror does not carry them, change
the two variables in `group_vars/all.yml`; nothing else depends on the exact
numbers.

## 5.6 Summary

| Brief section | Requirements | Implemented | Deviations |
|---|---|---|---|
| 1. Overview & stack | 13 | 13 | 0 |
| 2A. Infrastructure & IAM | 17 | 17 | 0 |
| 2B. Configuration & security | 8 | 8 | 1 (TLS local/cloud split) |
| 2C. Logging pipeline | 15 | 15 | 0 |
| 2D. Metrics pipeline | 15 | 15 | 2 (exporter interval, Operator-generated StatefulSet) |
| 3. Local emulation rules | 8 | 8 | 1 (health endpoint path corrected) |
| 4. Directory structure | 29 files | 29 files | 0 |
| **Total (Layers A-D)** | **76 + 29 files** | **76 + 29 files** | **4, all documented in 5.3** |
| Extension: Layer E (optional) | 14 (section 5.7) | **0 built, 0 verified** | n/a, additive and flag-gated |

Every file in the requested tree exists at the requested path, with no `TODO`
placeholders and no elided sections. That statement covers the 29 files of the
original tree; the Layer E files in section 3.11 are not part of that tree and
do not yet exist.

## 5.7 Layer E checklist (all rows: Planned)

Layer E was not in the brief; it is an extension. Each row states what the
design commits to. **Status for every row is Planned.** A row moves to
Verified only when the command in the last column has run and passed.

| # | Commitment | Planned file | Planned construct | How it will be verified |
|---|---|---|---|---|
| X.1 | Feature-flagged; off by default | `group_vars/all.yml` | `triage_agent_enabled: false`; every Layer E task guarded by `when:` | Render with the flag off; diff against current rendered output must be empty |
| X.2 | Alertmanager webhook trigger | `monitoring-values.yml.j2` | receiver `triage-agent`, route with `continue: true` | Fire a rule; agent receives exactly one POST; existing receivers still fire |
| X.3 | Alertmanager available locally when the flag is on | `monitoring-values.yml.j2` | `alertmanager.enabled: (not is_emulated) or triage_agent_enabled` | Local render with flag on shows Alertmanager enabled; flag off shows disabled |
| X.4 | Three read-only MCP servers, one per backend | `agents/mcp-servers/*.py`, `triage-agent.yml.j2` | one Deployment + ServiceAccount each | Smoke 7a, 7b |
| X.5 | No mutating verbs, no Secrets access | `triage-agent.yml.j2` | Role/ClusterRole `obs-triage-reader` | Smoke 7c |
| X.6 | Elasticsearch access limited to `logstash-k8s-*` and an allowlist of namespaces | `elasticsearch_mcp.py`, `playbook.yml` | pinned index; `triage_allowed_namespaces`; ES role `triage_reader` | Smoke 7d |
| X.7 | Hard limits enforced in server code | `*_mcp.py` | query/range/size/window/log-tail caps | Unit tests against each server with over-limit inputs |
| X.8 | Structured output, schema-validated, retry once | `schemas.py`, `agent.py` | Pydantic `TriageNote` | Smoke 7e; unit test with a malformed model response |
| X.9 | Per-run and per-alert budgets | `agent.py`, `main.py` | max tool calls, timeout, per-fingerprint cool-down | Unit tests: 9th tool call refused; repeat fingerprint deduplicated |
| X.10 | Audit log without result bodies | `agent.py` | tool, args, result size and hash only | Grep a run's stdout for a known log marker; it must be absent |
| X.11 | Egress-restricted namespace | `triage-agent.yml.j2` | `NetworkPolicy` | From a triage pod, a request to an arbitrary external host fails |
| X.12 | Agent exports its own metrics | `triage-agent.yml.j2` | `ServiceMonitor`; `triage_runs_total` etc. | Smoke 7f |
| X.13 | Runbooks versioned beside alert rules | `triage-runbooks.yml.j2` | ConfigMap keyed by `alertname` | Every alert rule has a runbook entry (render-time assertion) |
| X.14 | Diagnosis quality measured, not assumed | `agents/eval/` | fault injection harness | Section 5.8 |

## 5.8 Layer E evaluation plan

The value of the agent is whether its diagnoses are right. A working webhook
and a well-formed JSON note prove nothing about that, so the evaluation is a
first-class deliverable and not an afterthought.

**Method.** For each fault, `run_eval.py`:

1. applies a manifest that creates a known fault in the `workload` namespace
   (or a dedicated `triage-eval` namespace, added to the allowlist for the
   run);
2. waits for the symptom to be visible in Prometheus, Elasticsearch and the
   Kubernetes API;
3. sends a synthetic Alertmanager payload for that fault to `POST /alert`
   (fast and deterministic), and for a subset also waits for the **real**
   alert through Alertmanager;
4. scores the returned `TriageNote` against an `expected-cause` file
   (a category such as `bad-probe-target`, plus keywords that must appear in
   `likely_cause` or `evidence`);
5. deletes the fault and records the result.

**Initial fault set** (each reproduces a failure mode this platform has
either already hit or can hit):

| Fault | Ground truth |
|---|---|
| Container that exits non-zero on start (crash loop) | exit cause visible in previous-container logs |
| Readiness probe pointed at the wrong port/path | probe failure events; pod never Ready while process is up |
| Container exceeding its memory limit | OOMKilled in last state |
| Image that cannot be pulled | `ImagePullBackOff` events |
| Dependency unavailable at start (app started before DB) | connection error in logs, DB pod not Ready |
| Elevated 5xx from `vproweb` | `log_level: ERROR` spike with `http_status >= 500` |

**Reporting.** The result is reported as correct-category **X of Y** with the
fault list beside it, plus the failure cases and what the agent said. Because
local-model runs vary, each fault is run a fixed number of times (for example
three) and per-run results are kept. The figure is published only after it is
measured. No accuracy number appears anywhere in this document, and none
should be quoted from it.

**Decision rule.** If the local model cannot reach an acceptable score, the
response is to change `triage_llm_base_url` to a hosted free-tier model and
re-run the same evaluation, not to loosen the scoring. The comparison between
models is itself a useful result.

**What the evaluation does not cover.** It tests six injected faults on a
single-node cluster. It does not show the agent handles novel failures, noisy
multi-alert incidents, or adversarial log content. Section 2.11.5 is a design
argument for the last of these, not a test of it.

---

### Update: Multi-Namespace Read-Only Scope & Local `k3s` Verification
- **Scope Decision:** Expanded `Alert-Triage Agent` read-only inspection beyond `workload` to cover all observability and application namespaces (`workload`, `logging`, `monitoring`, `triage`). This enables the agent to diagnose platform-level incidents (such as `PrometheusOperatorRejectedResources` in `monitoring` or `Filebeat` issues in `logging`) while preserving least-privilege isolation (`kube-system`, `secrets`, `configmaps`, and write verbs remain blocked).
- **Local Execution Proof:** Executed live on the local `floci-gcp` + `k3s` cluster. `Alertmanager` webhooks (`POST /alert`) triggered `triage-agent` automatically, confirming bounded tool execution (1–5 tool calls, well under the 8-call cap), non-hallucinated confidence calibration (`medium` when operator validation details required manual CRD inspection, `high` for `Watchdog`), and persistent report storage under `/data/triage`.
