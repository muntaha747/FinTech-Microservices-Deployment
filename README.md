# WezvaTech – Ledger Microservice Deployment

Deployment guide for the **Ledger** microservice on a local **Kind** cluster (`powerful-cluster`) running on EC2, with **Argo Rollouts (Blue-Green)**, **HashiCorp Vault + Vault Secrets Operator**, **Calico**, **HPA**, and backing services on AWS (**RDS MySQL**, **MSK Kafka**, **S3**, **ECR**).
---

## Table of Contents

1. [What the Ledger Service Does](#1-what-the-ledger-service-does)
2. [Architecture & Environment](#2-architecture--environment)
3. [AWS Backing Services – RDS MySQL & MSK Kafka](#3-aws-backing-services--rds-mysql--msk-kafka)
4. [Kubernetes Objects Used](#4-kubernetes-objects-used)
5. [Repository Structure](#5-repository-structure)
6. [Prerequisites](#6-prerequisites)
7. [Create the Kind Cluster](#7-create-the-kind-cluster)
8. [Install Calico CNI](#8-install-calico-cni)
9. [Install Vault](#9-install-vault)
10. [Store Secrets in Vault](#10-store-secrets-in-vault)
11. [Configure Vault Kubernetes Auth, Policy & Role](#11-configure-vault-kubernetes-auth-policy--role)
12. [Install Vault Secrets Operator](#12-install-vault-secrets-operator)
13. [Install Argo Rollouts](#13-install-argo-rollouts)
14. [Create the ECR Image Pull Secret](#14-create-the-ecr-image-pull-secret)
15. [Deploy the Ledger Service](#15-deploy-the-ledger-service)
16. [Access the App & Check Health Probes](#16-access-the-app--check-health-probes)
17. [Blue-Green Release with Argo Rollouts](#17-blue-green-release-with-argo-rollouts)
18. [Autoscaling – Metrics Server & HPA](#18-autoscaling--metrics-server--hpa)
19. [Vault UI Access](#19-vault-ui-access)
20. [Troubleshooting](#20-troubleshooting)

---

## 1. What the Ledger Service Does

- Opens a **MySQL transaction**, locks the user's account row, checks the balance, debits the user, credits the merchant, and saves a small transaction record.
- Packages the large JSON response from the bank networks and uploads it to **S3**. If the merchant needs a **PDF receipt**, it generates it and stores it in S3.

**Goals**

| Goal | How |
|---|---|
| High Availability – zero downtime | Argo Rollouts Blue-Green, readiness probes, RDS Multi-AZ |
| Disaster Recovery – no data loss | RDS automated backups, Blue-Green DB upgrades |
| Autoscaling | HPA for pods, RDS read replicas for DB reads |

---

## 2. Architecture & Environment

```
Browser ──> EC2 Public IP :30001 ──> Kind control-plane (port mapping) ──> ledger-svc ──> Ledger pods (ns: ledger)
                                                                                         │
                       Vault (ns: default) ──> Vault Secrets Operator ──> K8s Secrets ───┤
                                                                                         ├──> RDS MySQL  (mysql-svc, ExternalName)
                                                                                         ├──> MSK Kafka
                                                                                         └──> S3 bucket
```

| Item | Value |
|---|---|
| Kind cluster | `powerful-cluster` (1 control-plane + 3 workers) |
| App namespace | `ledger` |
| Vault namespace | `default` (pod `vault-0`, svc `vault`) |
| Vault Secrets Operator namespace | `default` |
| ServiceAccount | `wezvatech-admin` |
| ECR image | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/fintech-ledgerservice:<tag>` |
| ECR region | `us-east-1` |
| RDS endpoint | `wezvadb-main-blue.cwhyq2cc07gy.us-east-1.rds.amazonaws.com` |
| S3 bucket | `wezvatech-ledger-receipts-prod-env` |
| Kafka | AWS MSK Serverless `fintech-demo-cluster`, topic `fraud-events` (`MSK_BOOTSTRAP_SERVERS`) |
| Host-mapped NodePorts | `30000–30019` |

**NodePort allocation**

| Service | NodePort |
|---|---|
| `ledger-svc` (Active) | `30001` |
| `ledgernew-svc` (Preview) | `30002` |
| `vault` UI/API | `30010` |

> Only ports **30000–30019** are mapped from the Kind control-plane to the EC2 host. Any NodePort outside this range is not reachable from outside.

---

## 3. AWS Backing Services – RDS MySQL & MSK Kafka

**Why RDS**
1. We choose the server type; AWS creates the server, installs and maintains MySQL.
2. High Availability (Multi-AZ).
3. Automated patching.
4. Managed version upgrades.
5. Automated backups.

**RDS Proxy benefits**
- Reduces DB load by pooling connections.
- Automatic failover.
- Better security with AWS Secrets Manager / IAM authentication.

**Upgrade & scaling strategy**
- Lower environments: **in-place** upgrade. Higher environments: **Blue-Green** upgrade.
- Major version upgrade once every 1–2 years.
- Version upgrades and vertical scaling (CPU/RAM) use **Blue-Green**.
- On high read concurrency: split reads from writes and add **3 read replicas** (more as needed).

### 3.1 RDS MySQL – `deployment-project/terraform-db`

What this Terraform creates (lab setup):

| Resource | Value |
|---|---|
| Blue DB | `wezvadb-main-blue` – MySQL `8.0.46`, `db.t3.micro`, 20 GB, DB name `mywezvadb`, user `admin` |
| Green DB | `wezvadb-main-green` – restored from snapshot `wezvadb-main-blue-manual-snapshot`, version `target_db_engine_version` (default `8.4.8`) |
| Network | Default VPC, `publicly_accessible = true`, SG `rds_sg` allows `3306` |
| DNS | Route 53 private zone `wezvatech-9739110917.internal`, CNAME `prod.db.wezvatech-9739110917.internal` → Blue (or Green after switchover) |
| Backups | 7-day retention |
| Region | `us-east-1` (`aws_region`) |

| Variable | Default | Purpose |
|---|---|---|
| `trigger_green_creation` | `false` | Snapshot Blue and create Green |
| `trigger_switchover` | `false` | Point the Route 53 CNAME to Green |
| `delete_source_db` | `false` | Delete Blue and the manual snapshot |
| `target_db_engine_version` | `8.4.8` | Green DB version |
| `target_instance_type` | `db.t3.micro` | Green DB instance size |

```bash
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project/terraform-db
```

**Step 1 – Create the DB (Blue)**
```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

**Step 2 – Create the upgraded Green DB**
```bash
terraform plan -var="trigger_green_creation=true" -var="target_db_engine_version=8.4.8" -out tfplan
terraform apply tfplan
```

**Step 3 – Switch DNS to Green**
```bash
terraform plan -var="trigger_green_creation=true" -var="target_db_engine_version=8.4.8" -var="trigger_switchover=true" -out tfplan
terraform apply tfplan
```

**Step 4 – Delete the old Blue DB**
```bash
terraform plan -var="trigger_green_creation=true" -var="target_db_engine_version=8.4.8" -var="trigger_switchover=true" -var="delete_source_db=true" -out tfplan
terraform apply tfplan
```

**Step 5 – Destroy everything (lab cleanup only)**
```bash
terraform destroy -auto-approve
```

> Keep passing every `-var` from the previous steps. Dropping one (e.g. `trigger_green_creation`) makes Terraform destroy that DB.
>
> The Route 53 zone is **private** (resolvable only inside the VPC). The Kind cluster reaches RDS through `mysql-svc` (ExternalName), so after the switchover update `externalName` in `service-networking/dbservice.yml` to the Green endpoint and re-apply it.
>
> `tfplan` can contain secrets – don't commit it.

### 3.2 MSK Kafka (Serverless) – `deployment-project/terraform-kafka`

Creates MSK Serverless cluster `fintech-demo-cluster` in the default VPC (IAM auth, port `9098`) and the topic `fraud-events` (3 partitions).

```bash
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project/terraform-kafka
terraform init
terraform apply
export KAFKA_BROKER=$(terraform output -raw bootstrap_brokers_sasl_iam)
echo $KAFKA_BROKER
```

Send test events to `fraud-events`:
```bash
pip install kafka-python aws-msk-iam-sasl-signer-python
python3 fraud-events-generations.py
```

> Use the `bootstrap_brokers_sasl_iam` output as `MSK_BOOTSTRAP_SERVERS` in `deployment.yml` (Section 15.2).

---

## 4. Kubernetes Objects Used

The Ledger service is **stateless**.

| # | Object | Purpose |
|---|---|---|
| 1 | Namespace | `ledger` |
| 2 | Argo Rollout | Blue-Green deployment → ReplicaSet → Pods |
| | ↳ Init container | Waits until `mysql-svc` resolves |
| | ↳ Main container | Ledger app: preStop hook, volume mounts, requests/limits, port 8080, liveness/readiness probes |
| | ↳ Pod settings | Replicas, node affinity (`disktype=ssd`), labels, annotations, volumes |
| 3 | Services | `ledger-svc` (Active), `ledgernew-svc` (Preview), `mysql-svc` (ExternalName → RDS) |
| 4 | ConfigMap | `wezvaspringbootapp` → `application.properties.orig`: log levels, Actuator + health probes, Hikari pool, DB URL (`jdbc:mysql://mysql-svc/mywezvadb`), Kafka, S3 |
| 5 | Secrets (from Vault) | `aws-secret`, `database-secret`, `database-ssl` |
| 6 | ServiceAccount | `wezvatech-admin` – used by Vault Secrets Operator |
| 7 | Network Policies | `default-deny` (all ingress) + Calico `allow-sprintboot-ingress` (TCP 8080 in, all egress) |
| 8 | ResourceQuota | `mem-cpu-quota` – requests 3 CPU / 3Gi, limits 4 CPU / 5Gi |
| 9 | HPA | `wezvaspringbootapp-hpa` – 1–2 replicas, memory 80% |

---

## 5. Repository Structure

```
FinTech-Microservices-Deployment/
├── README.md
└── deployment-project/
    ├── kind-cluster.yaml                  # Kind cluster config (Section 7)
    ├── calico/                            # Local copies of the Calico manifests
    ├── terraform-db/                      # RDS MySQL Terraform
    ├── terraform-kafka/                   # MSK Kafka Terraform + test event generator
    └── ledger-microservice/
        ├── springboot-manifests-k8s/
        │   ├── deployment.yml             # Argo Rollout (Blue-Green)
        │   ├── configmap/                 # application.properties ConfigMap
        │   ├── rbac/                      # ServiceAccount
        │   ├── vault-auth-connection/     # VaultConnection + VaultAuth
        │   ├── secrets/                   # VaultStaticSecrets (aws, db, ssl)
        │   ├── service-networking/        # Services (active, preview, mysql ExternalName)
        │   └── hpa/                       # metrics-server + HPA
        ├── policies-k8s/                  # Network policies + ResourceQuota
        └── logging-k8s/                   # Fluent Bit DaemonSet
```

---

## 6. Prerequisites

Run on the EC2 host (Ubuntu).

**Docker, kubectl, Kind** – installed.

**Helm**
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**AWS CLI**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt install -y unzip jq && unzip awscliv2.zip
sudo ./aws/install --bin-dir /usr/bin --install-dir /usr/bin/aws-cli --update
aws --version
```

**AWS credentials** – configure once, stored in `~/.aws/credentials` (never hardcode keys in scripts or docs):
```bash
aws configure
aws sts get-caller-identity
```

**EC2 Security Group inbound rules** (source: *My IP* only)

| Port | Purpose |
|---|---|
| 22 | SSH |
| 30001 | Ledger Active |
| 30002 | Ledger Preview |
| 30010 | Vault UI (optional – prefer SSH tunnel) |

---

## 7. Create the Kind Cluster

`deployment-project/kind-cluster.yaml`
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: powerful-cluster
nodes:
- role: control-plane
  extraPortMappings:             # NodePorts 30000-30019 -> EC2 host
  - containerPort: 30000
    hostPort: 30000
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30002
    hostPort: 30002
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30003
    hostPort: 30003
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30004
    hostPort: 30004
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30005
    hostPort: 30005
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30006
    hostPort: 30006
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30007
    hostPort: 30007
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30008
    hostPort: 30008
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30009
    hostPort: 30009
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30010
    hostPort: 30010
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30011
    hostPort: 30011
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30012
    hostPort: 30012
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30013
    hostPort: 30013
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30014
    hostPort: 30014
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30015
    hostPort: 30015
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30016
    hostPort: 30016
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30017
    hostPort: 30017
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30018
    hostPort: 30018
    listenAddress: 0.0.0.0
    protocol: TCP
  - containerPort: 30019
    hostPort: 30019
    listenAddress: 0.0.0.0
    protocol: TCP
- role: worker
- role: worker
- role: worker
networking:
  disableDefaultCNI: true        # Calico is installed instead
```

```bash
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project
kind create cluster --config kind-cluster.yaml
kind get clusters
docker ps --format "table {{.Names}}\t{{.Ports}}"
```
- `docker ps` must show `0.0.0.0:30000-30019->30000-30019/tcp` on `powerful-cluster-control-plane`.
- Nodes stay `NotReady` until Calico is installed (next step).

---

## 8. Install Calico CNI

Uses the local copies in `deployment-project/calico/` (operator `v1.32.7` / Calico v3.27). `custom-resources.yaml` also creates the Calico **APIServer**, which is needed for the `projectcalico.org/v3` network policy in `policies-k8s/`.
```bash
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project
kubectl create -f calico/tigera-operator.yaml
kubectl create -f calico/custom-resources.yaml
kubectl get pods -n calico-system -w
kubectl get nodes
```
All nodes must show `Ready`.

---

## 9. Install Vault

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault --set "server.dev.enabled=true"
kubectl get pods -w
```
- Installs Vault in **dev mode** in the `default` namespace. Root token: `root`.

Expose Vault on NodePort `30010`:
```bash
kubectl patch svc vault -n default -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":8200,"targetPort":8200,"nodePort":30010}]}}'
```

Use the Vault CLI from the EC2 host:
```bash
echo 'export VAULT_ADDR=http://127.0.0.1:30010' >> ~/.bashrc && source ~/.bashrc
vault status
vault login root
```

> ⚠️ Dev mode uses `inmem` storage. **If the Vault pod restarts, all secrets, policies and roles are lost** — redo Sections 10 and 11.

---

## 10. Store Secrets in Vault

Run from the manifests folder:
```bash
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project/ledger-microservice/springboot-manifests-k8s
```

**10.1 – Enable the KV v2 engine** (one time)
```bash
kubectl exec -it vault-0 -- vault secrets enable -path=internal kv-v2
```
> `path is already in use at internal/` → already enabled, continue.

**10.2 – Database credentials**
```bash
kubectl exec -it vault-0 -- vault kv put internal/database/config username="admin" password="<DB_PASSWORD>"
```

**10.3 – Database SSL certificate**

Generate a self-signed cert (stored in `vault-auth-connection/`, git-ignored):
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout vault-auth-connection/tls.key \
  -out vault-auth-connection/tls.crt \
  -subj "/CN=database.ledger.svc.cluster.local/O=WezvaTech"
```
Store it in Vault:
```bash
jq -n --arg cert "$(<vault-auth-connection/tls.crt)" --arg key "$(<vault-auth-connection/tls.key)" '{"tls.crt": $cert, "tls.key": $key}' | kubectl exec -i vault-0 -- vault kv put internal/database/ssl -
```
- `jq` builds JSON from the files; `-` makes Vault read it from stdin, keeping the multi-line cert intact.

**10.4 – AWS credentials** (read from `~/.aws/credentials`, never typed)
```bash
AK=$(aws configure get aws_access_key_id)
SK=$(aws configure get aws_secret_access_key)
echo ${AK:0:4}****

jq -n --arg ak "$AK" --arg sk "$SK" '{access_key:$ak, secret_access_key:$sk}' | kubectl exec -i vault-0 -- vault kv put internal/aws/config -
unset AK SK
```
- Keys go to Vault via stdin — they never appear in the command line or shell history.

**10.5 – Verify**
```bash
kubectl exec -it vault-0 -- vault kv get internal/database/config
kubectl exec -it vault-0 -- vault kv get internal/database/ssl
kubectl exec -it vault-0 -- vault kv get -format=json internal/aws/config | jq '.data.data | keys'
```

| Vault path | Keys |
|---|---|
| `internal/database/config` | `username`, `password` |
| `internal/database/ssl` | `tls.crt`, `tls.key` |
| `internal/aws/config` | `access_key`, `secret_access_key` |

---

## 11. Configure Vault Kubernetes Auth, Policy & Role

**11.1 – Enable Kubernetes auth** (one time)
```bash
kubectl exec -it vault-0 -- vault auth enable kubernetes
```
> `path is already in use` → already enabled, continue.

**11.2 – Point Vault to the Kubernetes API**
```bash
kubectl exec -it vault-0 -- sh -c 'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
```
- Vault uses this API to verify ServiceAccount tokens (TokenReview).
- `$KUBERNETES_PORT_443_TCP_ADDR` exists only inside pods — the single quotes make it expand inside `vault-0`.

**11.3 – Policy (what can be read)**
```bash
kubectl exec -i vault-0 -- vault policy write wezvatech-admin - <<EOF
path "internal/data/database/config" {
   capabilities = ["read"]
}
path "internal/data/database/ssl" {
   capabilities = ["read"]
}
path "internal/data/aws/config" {
   capabilities = ["read"]
}
EOF
```
- KV v2 policy paths include `/data/`.
- Re-running replaces the whole policy — always list **all** paths.

**11.4 – Role (who can log in)**
```bash
kubectl exec -it vault-0 -- vault write auth/kubernetes/role/wezvatech-admin \
  bound_service_account_names=wezvatech-admin \
  bound_service_account_namespaces=ledger \
  policies=wezvatech-admin \
  ttl=24h
```

| Parameter | Meaning |
|---|---|
| `bound_service_account_names` | Only SA `wezvatech-admin` can log in |
| `bound_service_account_namespaces` | Only from namespace `ledger` |
| `policies` | Gets read access defined in 11.3 |
| `ttl` | Vault token valid 24h |

Verify:
```bash
kubectl exec -it vault-0 -- vault read auth/kubernetes/role/wezvatech-admin
```
> The *"no audience configured"* warning is harmless.

---

## 12. Install Vault Secrets Operator

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator
kubectl get deploy vault-secrets-operator-controller-manager
kubectl get crd | grep vault
```
- Installed in the `default` namespace (same as Vault).
- The operator reads secrets from Vault and creates/updates Kubernetes Secrets in `ledger`.

---

## 13. Install Argo Rollouts

**Controller**
```bash
kubectl create namespace argo-rollouts
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl get pods -n argo-rollouts -w
```

**kubectl plugin**
```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64 && chmod +x ./kubectl-argo-rollouts-linux-amd64 && sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
kubectl argo rollouts version
```
> Use `linux-arm64` instead of `linux-amd64` on ARM machines (`uname -m` → `aarch64`).

---

## 14. Create the ECR Image Pull Secret

Kind is not on AWS, so it needs a Docker login to pull from private ECR. The ECR token **expires every 12 hours**.

```bash
kubectl create ns ledger
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project/ledger-microservice/springboot-manifests-k8s

export AWS_ACCESS_KEY_ID=$(vault kv get -field=access_key internal/aws/config)
export AWS_SECRET_ACCESS_KEY=$(vault kv get -field=secret_access_key internal/aws/config)

ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text)
REGION=us-east-1
TOKEN=$(aws ecr get-authorization-token --region $REGION --output text --query 'authorizationData[0].authorizationToken' | base64 -d | cut -d: -f2)

kubectl create secret docker-registry ecr-secret -n ledger \
  --docker-server=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$TOKEN" \
  --dry-run=client -o yaml > secrets/ecr-secret.yaml
```
- Writes the secret to `secrets/ecr-secret.yaml` (git-ignored); it is applied with the other secrets in 15.5.

| Item | Why |
|---|---|
| AWS keys | Authenticate to AWS (loaded from Vault) |
| `ACCOUNT` | Builds the registry URL `<ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com` |
| `TOKEN` | Temporary ECR password (12h) |
| `ecr-secret` | Referenced by the Rollout under `imagePullSecrets` |
| `--dry-run=client -o yaml` | Saves the Secret as a file instead of creating it directly |

**Refresh after 12 hours**
```bash
# re-run the TOKEN + create secret commands above, then:
kubectl apply -f secrets/ecr-secret.yaml
```

---

## 15. Deploy the Ledger Service

**15.1 – Label a node for the app** (Rollout uses node affinity `disktype=ssd`)
```bash
kubectl label nodes powerful-cluster-worker disktype=ssd --overwrite
kubectl get nodes -L disktype
```

**15.2 – Update the manifests before applying**

| File | Field | Set to | Currently in the file |
|---|---|---|---|
| `service-networking/dbservice.yml` (`mysql-svc`) | `externalName` | RDS endpoint (Section 3.1) | `wezvadb-main-blue.cwhyq2cc07gy.us-east-1.rds.amazonaws.com` ✅ |
| `service-networking/appservice.yml` (`ledger-svc`) | `nodePort` | `30001` | `31000` ⚠️ outside 30000–30019 |
| `service-networking/previewservice.yml` (`ledgernew-svc`) | `nodePort` | `30002` | `31100` ⚠️ outside 30000–30019 |
| `deployment.yml` | `image` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/fintech-ledgerservice:<tag>` | tag `rel-46-1bf7b424` ✅ |
| `deployment.yml` | `MSK_BOOTSTRAP_SERVERS` | `terraform output -raw bootstrap_brokers_sasl_iam` (Section 3.2, port `9098`) | placeholder ⚠️ |
| `deployment.yml` | `AWS_REGION` | Region of the S3 bucket | `us-east-1` |
| `deployment.yml` | TLS volume `secretName` | `database-ssl` | `database-ssl` ✅ |

**15.3 – Vault Operator files**

`rbac/serviceaccount.yaml`
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wezvatech-admin
  namespace: ledger
```

`vault-auth-connection/vault-connection.yaml` – where Vault is
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: ledger
spec:
  address: http://vault.default.svc:8200
```

`vault-auth-connection/vault-auth.yaml` – how to log in
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: wezva-auth
  namespace: ledger
spec:
  vaultConnectionRef: vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: wezvatech-admin
    serviceAccount: wezvatech-admin
```

`secrets/vault-static-secret.yaml` – DB credentials → `database-secret`
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: database-secret
  namespace: ledger
spec:
  vaultAuthRef: wezva-auth
  mount: internal
  path: database/config
  type: kv-v2
  destination:
    name: database-secret
    create: true
  refreshAfter: 30s
```

`secrets/vault-static-secret-ssl.yaml` – DB SSL → `database-ssl`
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: database-ssl
  namespace: ledger
spec:
  vaultAuthRef: wezva-auth
  mount: internal
  path: database/ssl
  type: kv-v2
  destination:
    name: database-ssl
    create: true
    type: kubernetes.io/tls
  refreshAfter: 30s
```

`secrets/vault-aws-secret.yaml` – AWS keys → `aws-secret`
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: aws-secret
  namespace: ledger
spec:
  vaultAuthRef: wezva-auth
  mount: internal
  path: aws/config
  type: kv-v2
  destination:
    name: aws-secret
    create: true
  refreshAfter: 30s
```

| VaultStaticSecret field | Meaning |
|---|---|
| `vaultAuthRef` | `VaultAuth` used to log in |
| `mount` / `path` | Vault location (`internal` + `aws/config`) – no `data/` here |
| `destination.name` | Kubernetes Secret created |
| `destination.type` | `kubernetes.io/tls` for certs, default `Opaque` |
| `refreshAfter` | Re-sync interval from Vault |

**15.4 – Rollout pod spec (`deployment.yml`)**
```yaml
     serviceAccountName: wezvatech-admin
     affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: disktype
                operator: In
                values:
                - ssd
     imagePullSecrets:
       - name: ecr-secret
     initContainers:
       - name: init-mydb
         image: busybox:1.28
         command: ['sh', '-c', "until nslookup mysql-svc.$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace).svc.cluster.local; do echo waiting for mydb; sleep 2; done"]
         resources:
            limits:
              cpu: 400m
              memory: 500Mi
            requests:
              cpu: 100m
              memory: 128Mi
     containers:
       - name: main
         image: 747240980649.dkr.ecr.us-east-1.amazonaws.com/fintech-ledgerservice:rel-46-1bf7b424
         imagePullPolicy: IfNotPresent
         lifecycle:
           preStop:
             exec:
               command: ["/bin/sh", "-c", "sleep 15"] # Gives Kafka client time to stop pulling new messages
         env:
         - name: AWS_ACCESS_KEY_ID
           valueFrom:
             secretKeyRef:
                name: aws-secret
                key: access_key
         - name: AWS_SECRET_ACCESS_KEY
           valueFrom:
             secretKeyRef:
                name: aws-secret
                key: secret_access_key
         - name: DB_USER
           valueFrom:
             secretKeyRef:
               name: database-secret
               key: username
         - name: DB_PASSWORD
           valueFrom:
             secretKeyRef:
               name: database-secret
               key: password
         - name: MSK_BOOTSTRAP_SERVERS
           value: "<bootstrap_brokers_sasl_iam from Section 3.2>"
         - name: AWS_REGION
           value: "us-east-1"
         - name: S3_BUCKET_NAME
           value: "wezvatech-ledger-receipts-prod-env"
         ports:
           - containerPort: 8080
         livenessProbe:
           httpGet:
              path: /actuator/health/liveness
              port: 8080
           initialDelaySeconds: 90
           periodSeconds:  45
           timeoutSeconds:  5
         readinessProbe:
           httpGet:
              path: /actuator/health/readiness
              port: 8080
           initialDelaySeconds: 90
           timeoutSeconds:  5
           periodSeconds: 5
         resources:
            limits:
              cpu: 400m
              memory: 1Gi
            requests:
              cpu: 100m
              memory: 128Mi
         volumeMounts:
         - name: appconfigmap
           mountPath: "/opt/wezva/application.properties.orig"
           subPath: application.properties.orig
         - name: tls-volume
           mountPath: /etc/tls
           readOnly: true
     volumes:
     - name: appconfigmap
       configMap:
         name: wezvaspringbootapp
         items:
         - key: application.properties.orig
           path: application.properties.orig
     - name: tls-volume
       secret:
          secretName: database-ssl
```
> Env var names must be exactly `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (underscores) for the AWS SDK. `key:` must match the key inside the Kubernetes Secret.
>
> The ConfigMap is mounted as `/opt/wezva/application.properties.orig`; Spring reads `${DB_USER}`, `${DB_PASSWORD}`, `${MSK_BOOTSTRAP_SERVERS}`, `${AWS_REGION}` and `${S3_BUCKET_NAME}` from the env vars above.

**15.5 – Apply in order** (from `deployment-project/ledger-microservice/springboot-manifests-k8s`)
```bash
kubectl apply -f rbac/
kubectl apply -f vault-auth-connection/
kubectl apply -f secrets/                      # 3 VaultStaticSecrets + ecr-secret.yaml
kubectl apply -f configmap/
kubectl apply -f service-networking/
kubectl apply -f deployment.yml
kubectl apply -f hpa/metric-server.yaml        # namespace kube-system (set in the file)
kubectl apply -f hpa/hpa.yml -n ledger         # no namespace in the file
kubectl apply -f ../policies-k8s/ -n ledger    # default-deny, Calico allow 8080, ResourceQuota
```
> `hpa.yml`, `default-deny.yml` and `resourcequota.yml` have no `namespace:` – always apply them with `-n ledger`. Don't add `-n ledger` to `metric-server.yaml` (it is `kube-system`).

**15.6 – Verify**
```bash
kubectl get vaultstaticsecret -n ledger
kubectl get secret database-secret database-ssl aws-secret ecr-secret -n ledger
kubectl get svc -n ledger
kubectl get hpa,resourcequota,networkpolicy -n ledger
kubectl argo rollouts get rollout wezvaspringbootapp -n ledger --watch
```

Shell into the app:
```bash
kubectl exec -it -c main <pod-name> -n ledger -- /bin/sh
```

---

## 16. Access the App & Check Health Probes

**App URLs** (from the browser)
```
Active : http://<EC2-PUBLIC-IP>:30001/books
Preview: http://<EC2-PUBLIC-IP>:30002/books
```

Test from the EC2 host:
```bash
curl -I http://localhost:30001/books
```

**Liveness / Readiness probes** – the Rollout probes `/actuator/health/liveness` and `/actuator/health/readiness` on port 8080 (Service port 80 → 8080).
```bash
curl -i http://localhost:30001/actuator/health/liveness
curl -i http://localhost:30001/actuator/health/readiness
```
`HTTP 200` + `{"status":"UP"}` = passing. `503` + `DOWN`/`OUT_OF_SERVICE` = failing.

**How Kubernetes sees the probes**
```bash
kubectl get pods -n ledger
kubectl describe pod -n ledger -l app.kubernetes.io/name=wezvaspringbootapp | grep -iE "liveness|readiness|unhealthy|killing"
kubectl get events -n ledger --sort-by=.lastTimestamp | grep -iE "probe|unhealthy"
```
- `READY 1/1` → readiness passing.
- Rising `RESTARTS` → liveness failing.

> Probes are enabled in the ConfigMap with `management.endpoint.health.probes.enabled=true`. Both probes start after `initialDelaySeconds: 90` (liveness every 45s, readiness every 5s, timeout 5s).

---

## 17. Blue-Green Release with Argo Rollouts

1. Update `image:` in `deployment.yml` to the new tag and apply:
   ```bash
   kubectl apply -f deployment.yml
   ```
2. New version (Green) starts behind `ledgernew-svc` → test on `:30002`.
3. Watch:
   ```bash
   kubectl argo rollouts get rollout wezvaspringbootapp -n ledger --watch
   ```
4. Promote Green to Active (`autoPromotionEnabled: false`):
   ```bash
   kubectl argo rollouts promote wezvaspringbootapp -n ledger
   ```
5. Roll back if needed:
   ```bash
   kubectl argo rollouts undo wezvaspringbootapp -n ledger --to-revision=1
   ```

---

## 18. Autoscaling – Metrics Server & HPA

**Metrics Server** (runs in `kube-system`)

`hpa/metric-server.yaml` is metrics-server `v0.7.2` with `--kubelet-insecure-tls` already added to `args:` (Kind kubelets use self-signed certs).

```bash
kubectl apply -f hpa/metric-server.yaml
kubectl get apiservices | grep metrics        # v1beta1.metrics.k8s.io ... True
kubectl get pods -n kube-system -w
kubectl top nodes
kubectl top pods -n ledger
```

**HPA**
`hpa/hpa.yml` – `wezvaspringbootapp-hpa` scales the Rollout `wezvaspringbootapp` between **1 and 2** replicas on **memory 80%**.
```bash
kubectl apply -f hpa/hpa.yml -n ledger
kubectl get hpa -n ledger -w
```
`TARGETS` should show values like `memory: 60%/80%`, not `<unknown>`.

---

## 19. Vault UI Access

**Option A – SSH tunnel (recommended)** – from the Mac:
```bash
ssh -i ~/Downloads/FinTech-Enterprise-Project.pem -L 8200:127.0.0.1:30010 ubuntu@<EC2-PUBLIC-DNS>
```
Open `http://localhost:8200/ui`

**Option B – direct** (Security Group allows 30010 from *My IP*):
Open `http://<EC2-PUBLIC-IP>:30010/ui`

Login: **Method = Token**, **Token = `root`** (dev mode).

---

## 20. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `path is already in use` (Vault) | Already enabled – skip that step |
| `connection refused` on `vault` CLI | `VAULT_ADDR` not set → `export VAULT_ADDR=http://127.0.0.1:30010` |
| Kubernetes Secret not created | `kubectl describe vaultstaticsecret <name> -n ledger` → check Events |
| `permission denied` / `403` from Vault | Path missing in policy (11.3) |
| Vault login fails / `invalid role` | Role namespace must be `ledger`, SA `wezvatech-admin` (11.4) |
| `FailedMount ... secret "X" not found` | `secretName` in Rollout ≠ `destination.name` in VaultStaticSecret |
| `ImagePullBackOff` | `ecr-secret` missing or token expired (>12h) → Section 14 |
| Pod `Pending` | No node labeled `disktype=ssd` → 15.1 |
| `namespace "kube-system" does not match "ledger"` | Don't use `-n ledger` with `hpa/metric-server.yaml` |
| HPA / ResourceQuota / default-deny in `default` namespace | Applied without `-n ledger` → delete and re-apply with `-n ledger` |
| `last-applied-configuration` warning | Harmless – annotation is auto-added |
| App not reachable from browser | NodePort must be in `30000–30019` + Security Group rule |
| `Metrics API not available` | metrics-server not running / missing `--kubelet-insecure-tls` |
| Everything gone in Vault | Dev mode `inmem` storage reset on pod restart → redo Sections 10–11 |

**Useful logs**
```bash
kubectl logs -n default deploy/vault-secrets-operator-controller-manager | tail -30
kubectl logs -n ledger -l app.kubernetes.io/name=wezvaspringbootapp -c main --tail=100
kubectl logs -n argo-rollouts deploy/argo-rollouts | tail -30
```
Kind (PVC on EC2 EBS)

Persistent storage for the Ledger app on the **running** Kind cluster `powerful-cluster` (namespace `ledger`), using Kind's built-in `standard` StorageClass. Data is stored on the EC2 instance's existing EBS disk. No cluster recreate needed.

```
EC2 EBS disk ──> Kind worker (local-path) ──> PV (auto) ──> ledger-pvc ──> Pod /data
```

---

## 1. Check the StorageClass and free disk space

```bash
kubectl get storageclass
```
```bash
df -h /
```
- Must show `standard (default)`.
- EC2 disk must have at least **50G** free.

---

## 2. Create the 50Gi PVC

```bash
cat > ledger-pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ledger-pvc
  namespace: ledger
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 50Gi
EOF
```
```bash
kubectl delete pvc ledger-pvc -n ledger --ignore-not-found
```
```bash
kubectl apply -f ledger-pvc.yaml
```
- The PV is created automatically when a pod first uses the PVC.
- `Pending` is normal until the Rollout uses it.
- `local-path` cannot resize – to change size, delete and recreate the PVC.

---

## 3. Mount the PVC in the Rollout (`deployment.yml`)

```bash
cd ~/DevOps/FinTech-Microservices-Deployment/deployment-project/ledger-microservice/springboot-manifests-k8s
```

Under the `main` container `volumeMounts:`
```yaml
         - name: ledger-data
           mountPath: /data
```

Under `volumes:`
```yaml
     - name: ledger-data
       persistentVolumeClaim:
         claimName: ledger-pvc
```
- `/data` is the folder **inside the container**. Anything the app writes there is stored on the PVC.

---

## 4. Send the app logs to `/data` (`configmap/configmap.yml`)

Add after the `logging.level` lines:
```
        logging.file.name=/data/logs/ledger.log
        logging.logback.rollingpolicy.max-file-size=50MB
        logging.logback.rollingpolicy.max-history=7
```
- Logs go to `/data/logs/ledger.log` on the PVC.
- Rotated at 50 MB, last 7 files kept.

---

## 5. Apply

```bash
kubectl apply -f configmap/configmap.yml
```
```bash
kubectl apply -f deployment.yml
```
```bash
kubectl argo rollouts get rollout wezvaspringbootapp -n ledger --watch
```

---

## 6. Verify

```bash
kubectl get pvc -n ledger
```
```bash
kubectl get pods -n ledger
```
```bash
kubectl exec -it -c main <pod-name> -n ledger -- ls -l /data/logs/
```
- PVC must show `Bound`.

---

## 7. Test that data survives a pod restart

```bash
kubectl exec -it -c main <pod-name> -n ledger -- sh -c 'echo persistent > /data/test.txt'
```
```bash
kubectl delete pod <pod-name> -n ledger
```
```bash
kubectl get pods -n ledger
```
```bash
kubectl exec -it -c main <new-pod-name> -n ledger -- cat /data/test.txt
```
- Prints `persistent` → storage is persistent.

---

## 8. Where the data lives on EC2

```bash
kubectl get pv
```
```bash
docker exec powerful-cluster-worker ls /var/local-path-provisioner/
```
# volume id and select that volume. the reason it is inside the docker becasue the nodes are our containers.
sudo su
cd /var/lib/docker

# If it is the EKS Workder node the path will be in the --> 
/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv-name>/mount

---


# WezvaTech – Payment Microservice Deployment
