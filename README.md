<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ledger Deployment Guide</title>
<style>
:root{
  --bg:#0f1117; --panel:#161a23; --code-bg:#0b1f1d; --border:#2a2f3d;
  --purple:#b794f6; --purple-strong:#d6bcfa; --teal:#2dd4bf; --teal-dim:#134e4a;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--purple);font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:1000px;margin:0 auto;padding:32px 16px 80px}
h1,h2,h3,h4{color:var(--purple-strong);line-height:1.3}
h1{font-size:2rem;border-bottom:2px solid var(--border);padding-bottom:12px}
h2{margin-top:48px;border-bottom:1px solid var(--border);padding-bottom:8px}
a{color:var(--purple-strong)}
strong{color:var(--purple-strong)}
hr{border:0;border-top:1px solid var(--border);margin:32px 0}
blockquote{margin:16px 0;padding:8px 16px;border-left:4px solid var(--purple);background:var(--panel);border-radius:6px}
code{font-family:"SF Mono",Menlo,Consolas,monospace;font-size:.92em}
:not(pre)>code{color:var(--teal);background:var(--code-bg);padding:2px 6px;border-radius:4px}
.code-wrap{position:relative;margin:16px 0}
pre{margin:0;background:var(--code-bg);border:1px solid var(--teal-dim);border-radius:8px;padding:16px;padding-right:84px;overflow-x:auto}
pre code{color:var(--teal);white-space:pre}
.copy{position:absolute;top:8px;right:8px;background:var(--teal-dim);color:var(--teal);border:1px solid var(--teal);border-radius:6px;padding:4px 10px;font-size:13px;cursor:pointer}
.copy:hover{background:var(--teal);color:#04201d}
.copy.done{background:var(--teal);color:#04201d}
table{border-collapse:collapse;width:100%;margin:16px 0;display:block;overflow-x:auto}
th,td{border:1px solid var(--border);padding:8px 12px;text-align:left;vertical-align:top}
th{background:var(--panel);color:var(--purple-strong)}
li{margin:4px 0}
</style>
</head>
<body>
<main id="content">Loading…</main>
<script type="text/markdown" id="md"># WezvaTech – Ledger Microservice Deployment

Deployment guide for the **Ledger** microservice on a local **Kind** cluster (`powerful-cluster`) running on EC2, with **Argo Rollouts (Blue-Green)**, **HashiCorp Vault + Vault Secrets Operator**, **Calico**, **HPA**, and backing services on AWS (**RDS MySQL**, **MSK Kafka**, **S3**, **ECR**).

---

## Table of Contents

1. [What the Ledger Service Does](#1-what-the-ledger-service-does)
2. [Architecture & Environment](#2-architecture--environment)
3. [Database – AWS RDS MySQL (Blue-Green)](#3-database--aws-rds-mysql-blue-green)
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
| ServiceAccount | `wezvatech-admin` |
| ECR image | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/wezvatechledger:<tag>` |
| ECR region | `us-east-1` |
| RDS endpoint | `wezvadb-main-blue.cwhyq2cc07gy.us-east-1.rds.amazonaws.com` |
| S3 bucket | `wezvatech-ledger-receipts-prod-env` |
| Kafka | AWS MSK (`MSK_BOOTSTRAP_SERVERS`) |
| Host-mapped NodePorts | `30000–30019` |

**NodePort allocation**

| Service | NodePort |
|---|---|
| `ledger-svc` (Active) | `30001` |
| `ledgernew-svc` (Preview) | `30002` |
| `vault` UI/API | `30010` |

> Only ports **30000–30019** are mapped from the Kind control-plane to the EC2 host. Any NodePort outside this range is not reachable from outside.

---

## 3. Database – AWS RDS MySQL (Blue-Green)

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

> **Run this in the Data VPC**, in the 3 private DB subnets. The Apps VPC reaches it through the Transit Gateway.

```bash
git clone https://github.com/wezva-fintech/terraform-modules.git
cd terraform-modules/rds-mysql-bluegreen
```

**Step 1 – Create the DB (Blue)**
```bash
terraform init
terraform plan -var="source_db_engine_version=8.0.43" -out db8.0.43
terraform apply "db8.0.43"
```

**Step 2 – Create the upgraded Green DB**
```bash
terraform plan -var="source_db_engine_version=8.0.43" -var="trigger_green_creation=true" -var="target_db_engine_version=8.4.4" -out dbupgrade8.4.4
terraform apply "dbupgrade8.4.4"
```

**Step 3 – Switch DNS to Green**
```bash
terraform plan -var="source_db_engine_version=8.0.43" -var="trigger_green_creation=true" -var="target_db_engine_version=8.4.4" -var="trigger_switchover=true" -out dbswitchdns
terraform apply "dbswitchdns"
```

**Step 4 – Delete the old Blue DB**
```bash
terraform plan -var="source_db_engine_version=8.0.43" -var="trigger_green_creation=true" -var="target_db_engine_version=8.4.4" -var="trigger_switchover=true" -var="delete_source_db=true" -out dbdeleteblue
terraform apply "dbdeleteblue"
```

**Step 5 – Destroy everything (lab cleanup only)**
```bash
terraform destroy -auto-approve
```

> `source_db_engine_version` must always equal the version currently running on the Blue DB.

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
| 4 | ConfigMap | Kafka, DB, log level, log file, heap memory settings |
| 5 | Secrets (from Vault) | `aws-secret`, `database-secret`, `database-ssl` |
| 6 | ServiceAccount | `wezvatech-admin` – used by Vault Secrets Operator |
| 7 | Network Policies | Calico ingress/egress rules |
| 8 | ResourceQuota | Namespace limits |
| 9 | HPA | Pod autoscaling on CPU/memory |

---

## 5. Repository Structure

```
springboot-manifests-k8s/
├── README.md
├── deployment.yml              # Argo Rollout (Blue-Green)
├── configmap/                  # application.properties ConfigMap
├── rbac/                       # ServiceAccount, Roles
├── vault-auth-connection/      # VaultConnection + VaultAuth
├── secrets/                    # VaultStaticSecrets (aws, db, ssl)
├── service-networking/         # Services + Network Policies
└── hpa/                        # metrics-server + HPA
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

`kindcluster.yml`
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: powerful-cluster
networking:
  disableDefaultCNI: true        # Calico is installed instead
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
nodes:
  - role: control-plane
    extraPortMappings:           # NodePorts 30000-30019 -> EC2 host
      - { containerPort: 30000, hostPort: 30000, protocol: TCP }
      - { containerPort: 30001, hostPort: 30001, protocol: TCP }
      - { containerPort: 30002, hostPort: 30002, protocol: TCP }
      - { containerPort: 30003, hostPort: 30003, protocol: TCP }
      - { containerPort: 30004, hostPort: 30004, protocol: TCP }
      - { containerPort: 30005, hostPort: 30005, protocol: TCP }
      - { containerPort: 30006, hostPort: 30006, protocol: TCP }
      - { containerPort: 30007, hostPort: 30007, protocol: TCP }
      - { containerPort: 30008, hostPort: 30008, protocol: TCP }
      - { containerPort: 30009, hostPort: 30009, protocol: TCP }
      - { containerPort: 30010, hostPort: 30010, protocol: TCP }
      - { containerPort: 30011, hostPort: 30011, protocol: TCP }
      - { containerPort: 30012, hostPort: 30012, protocol: TCP }
      - { containerPort: 30013, hostPort: 30013, protocol: TCP }
      - { containerPort: 30014, hostPort: 30014, protocol: TCP }
      - { containerPort: 30015, hostPort: 30015, protocol: TCP }
      - { containerPort: 30016, hostPort: 30016, protocol: TCP }
      - { containerPort: 30017, hostPort: 30017, protocol: TCP }
      - { containerPort: 30018, hostPort: 30018, protocol: TCP }
      - { containerPort: 30019, hostPort: 30019, protocol: TCP }
  - role: worker
  - role: worker
  - role: worker
```

```bash
kind create cluster --config kindcluster.yml
kind get clusters
docker ps --format "table {{.Names}}\t{{.Ports}}"
```
- `docker ps` must show `0.0.0.0:30000-30019->30000-30019/tcp` on `powerful-cluster-control-plane`.
- Nodes stay `NotReady` until Calico is installed (next step).

---

## 8. Install Calico CNI

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/custom-resources.yaml
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
cd ~/DevOps/WezvaTech-Project/mini-project/ledger/springboot-manifests-k8s
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

Generate a self-signed cert:
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=database.ledger.svc.cluster.local/O=WezvaTech"
```
Store it in Vault:
```bash
jq -n --arg cert "$(<tls.crt)" --arg key "$(<tls.key)" '{"tls.crt": $cert, "tls.key": $key}' | kubectl exec -i vault-0 -- vault kv put internal/database/ssl -
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
helm install vault-secrets-operator hashicorp/vault-secrets-operator -n vault-secrets-operator-system --create-namespace
kubectl get pods -n vault-secrets-operator-system
kubectl get crd | grep vault
```
The operator reads secrets from Vault and creates/updates Kubernetes Secrets in `ledger`.

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

export AWS_ACCESS_KEY_ID=$(vault kv get -field=access_key internal/aws/config)
export AWS_SECRET_ACCESS_KEY=$(vault kv get -field=secret_access_key internal/aws/config)

ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text)
REGION=us-east-1
TOKEN=$(aws ecr get-authorization-token --region $REGION --output text --query 'authorizationData[0].authorizationToken' | base64 -d | cut -d: -f2)

kubectl create secret docker-registry ecr-secret -n ledger \
  --docker-server=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$TOKEN"
```

| Item | Why |
|---|---|
| AWS keys | Authenticate to AWS (loaded from Vault) |
| `ACCOUNT` | Builds the registry URL `<ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com` |
| `TOKEN` | Temporary ECR password (12h) |
| `ecr-secret` | Referenced by the Rollout under `imagePullSecrets` |

**Refresh after 12 hours**
```bash
kubectl delete secret ecr-secret -n ledger
# then re-run the TOKEN + create secret commands above
```

---

## 15. Deploy the Ledger Service

**15.1 – Label a node for the app** (Rollout uses node affinity `disktype=ssd`)
```bash
kubectl label nodes powerful-cluster-worker disktype=ssd --overwrite
kubectl get nodes -L disktype
```

**15.2 – Update the manifests before applying**

| File | What to set |
|---|---|
| `service-networking/` → `mysql-svc` | `externalName: wezvadb-main-blue.cwhyq2cc07gy.us-east-1.rds.amazonaws.com` |
| `service-networking/` → `ledger-svc` | `nodePort: 30001` |
| `service-networking/` → `ledgernew-svc` | `nodePort: 30002` |
| `deployment.yml` | `image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/wezvatechledger:<tag>` |
| `deployment.yml` | `MSK_BOOTSTRAP_SERVERS: "b-1.<cluster>.kafka.<region>.amazonaws.com:9094,b-2.<cluster>.kafka.<region>.amazonaws.com:9094"` |
| `deployment.yml` | TLS volume `secretName: database-ssl` |

**15.3 – Vault Operator files**

`rbac/serviceaccount.yml`
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

**15.4 – Secrets referenced in the Rollout (`deployment.yml`)**
```yaml
     serviceAccountName: wezvatech-admin
     imagePullSecrets:
       - name: ecr-secret
     containers:
       - name: main
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
           value: "<broker-1>:9094,<broker-2>:9094"
         - name: AWS_REGION
           value: "us-east-1"
         - name: S3_BUCKET_NAME
           value: "wezvatech-ledger-receipts-prod-env"
         volumeMounts:
         - name: tls-volume
           mountPath: /etc/tls
           readOnly: true
     volumes:
     - name: tls-volume
       secret:
         secretName: database-ssl
```
> Env var names must be exactly `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (underscores) for the AWS SDK. `key:` must match the key inside the Kubernetes Secret.

**15.5 – Apply in order** (do **not** pass `-n ledger` – each file sets its own namespace; metrics-server lives in `kube-system`)
```bash
kubectl apply -R -f rbac/
kubectl apply -R -f vault-auth-connection/
kubectl apply -R -f secrets/
kubectl apply -R -f configmap/
kubectl apply -R -f service-networking/
kubectl apply -f deployment.yml
kubectl apply -R -f hpa/
```

**15.6 – Verify**
```bash
kubectl get vaultstaticsecret -n ledger
kubectl get secret database-secret database-ssl aws-secret ecr-secret -n ledger
kubectl get svc -n ledger
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

> Probe endpoints return 404? Add `management.endpoint.health.probes.enabled=true` to `application.properties`.

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
```bash
wget https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml -O hpa/metric-server.yaml
```
Edit `hpa/metric-server.yaml` → under the `metrics-server` container `args:`, add:
```yaml
        - --kubelet-insecure-tls
```
(Kind kubelets use self-signed certs.)

```bash
kubectl apply -f hpa/metric-server.yaml
kubectl get apiservices | grep metrics        # v1beta1.metrics.k8s.io ... True
kubectl get pods -n kube-system -w
kubectl top nodes
kubectl top pods -n ledger
```

**HPA**
```bash
kubectl apply -f hpa/hpa.yml
kubectl get hpa -n ledger -w
```
`TARGETS` should show values like `15%/70%`, not `<unknown>`.

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
| `namespace "kube-system" does not match "ledger"` | Don't use `-n ledger` with `kubectl apply -R` |
| `last-applied-configuration` warning | Harmless – annotation is auto-added |
| App not reachable from browser | NodePort must be in `30000–30019` + Security Group rule |
| `Metrics API not available` | metrics-server not running / missing `--kubelet-insecure-tls` |
| Everything gone in Vault | Dev mode `inmem` storage reset on pod restart → redo Sections 10–11 |

**Useful logs**
```bash
kubectl logs -n vault-secrets-operator-system deploy/vault-secrets-operator-controller-manager | tail -30
kubectl logs -n ledger -l app.kubernetes.io/name=wezvaspringbootapp -c main --tail=100
kubectl logs -n argo-rollouts deploy/argo-rollouts | tail -30
```
</script>
<script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>
<script>
const src = document.getElementById('md').textContent;
const main = document.getElementById('content');
main.innerHTML = marked.parse(src, {gfm:true});
main.querySelectorAll('h1,h2,h3,h4').forEach(h=>{
  h.id = h.textContent.trim().toLowerCase().replace(/[^\w\s-]/g,'').replace(/\s/g,'-');
});
main.querySelectorAll('pre').forEach(pre=>{
  const wrap = document.createElement('div'); wrap.className='code-wrap';
  pre.parentNode.insertBefore(wrap, pre); wrap.appendChild(pre);
  const btn = document.createElement('button'); btn.className='copy'; btn.textContent='Copy';
  btn.onclick = async ()=>{
    const text = pre.innerText.replace(/\n$/,'');
    try { await navigator.clipboard.writeText(text); }
    catch(e){ const t=document.createElement('textarea'); t.value=text; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove(); }
    btn.textContent='Copied'; btn.classList.add('done');
    setTimeout(()=>{btn.textContent='Copy'; btn.classList.remove('done');},1500);
  };
  wrap.appendChild(btn);
});
</script>
</body>
</html>