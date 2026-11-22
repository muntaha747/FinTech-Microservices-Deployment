# Ledger Lab on Kind: Copy-Paste Guide (Ubuntu)

Kind cluster + Calico + Vault + Argo Rollouts + ECR secret + Ledger app + autoscaling.
This is my instructor's lab, **fixed so it works first time** on any Ubuntu machine (laptop or EC2).

> **How to read this file with colours:** open it in VS Code and press `Ctrl+Shift+V` (preview),
> or push it to GitHub (every code block gets a copy button).
> Every grey box is one copy-paste. Lines starting with `#` are comments, and bash ignores them.

| # | Step |
|---|---|
| 0 | [Install tools (one time per machine)](#0-install-tools-one-time-per-machine) |
| 1 | [AWS credentials](#1-aws-credentials) |
| 2 | [Create the Kind cluster (no default CNI)](#2-create-the-kind-cluster-no-default-cni) |
| 3 | [Install Calico CNI](#3-install-calico-cni) |
| 4 | [Install Vault + store DB secret and SSL cert](#4-install-vault--store-db-secret-and-ssl-cert) |
| 5 | [Install Argo Rollouts](#5-install-argo-rollouts) |
| 6 | [ECR image pull secret](#6-ecr-image-pull-secret) |
| 7 | [Vault Secrets Operator](#7-vault-secrets-operator) |
| 8 | [Network policies + deploy the Ledger app](#8-network-policies--deploy-the-ledger-app) |
| 9 | [Autoscaling (metrics-server + HPA)](#9-autoscaling-metrics-server--hpa) |
| 10 | [Cleanup](#10-cleanup) |
| ⚠️ | [Troubleshooting: errors I already hit](#troubleshooting-errors-i-already-hit) |
| 🔌 | [Port map: which tool runs on which port](#-port-map-which-tool-runs-on-which-port) |

---

## 🔌 Port map: which tool runs on which port

My kind cluster opens **122 ports** on the laptop (see `kind-config.yaml`).
Open any tool at **`http://localhost:<port>`** (on EC2: `http://<public-ip>:<port>` + open the port in the security group).

### How it works

```
browser → localhost:30100 → kind control-plane container (port 30100)
        → kube-proxy → Service with nodePort 30100 → Grafana pod (on ANY of the 11 nodes)
```

Kind publishes each port from the laptop into the control-plane container. Inside the cluster,
kube-proxy sends that port to the Service that owns it, wherever its pod is running.

**For every new tool, do these 3 steps:**

| Step | What | Command |
|---|---|---|
| **1** | Make the tool's Service a **NodePort** | `kubectl expose service <svc> --type=NodePort --target-port=<port> --name=<svc>-np -n <ns>` |
| **2** | Pin it to a **port from the table below** | `kubectl patch svc <svc>-np -n <ns> --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":<nodeport>}]'` |
| **3** | **Open** it in the browser | `http://localhost:<nodeport>` |

Full copy-paste examples are in [How to put a tool on its port](#how-to-put-a-tool-on-its-port-same-2-commands-for-every-tool).

### Port groups

| Host ports | Group | What goes here |
|---|---|---|
| **80, 443** | Ingress | ingress-nginx. Unlimited tools by hostname (`grafana.localhost`, `argocd.localhost`) |
| **30000–30019** | General | Prometheus + anything else |
| **30100–30119** | Observability | Grafana, Alertmanager, Kiali, Jaeger, OpenSearch… |
| **31000–31019** | Apps: ACTIVE | Live version of the apps (blue-green "active") |
| **31100–31119** | Apps: PREVIEW | New version being tested (blue-green "preview") |
| **32000–32019** | CD / GitOps | ArgoCD, Jenkins… |
| **32100–32119** | Security + spare | Falco UI, Vault UI, SonarQube, K8s dashboard… |

### Tool → port (my plan)

| Tool | Namespace | Service port (`--target-port`) | **NodePort** | URL | Login |
|---|---|---|---|---|---|
| Prometheus | monitoring | 9090 | **30000** | <http://localhost:30000> | none |
| Grafana | monitoring | 3000 | **30100** | <http://localhost:30100> | `admin` / see command below |
| Alertmanager | monitoring | 9093 | **30101** | <http://localhost:30101> | none |
| Kiali (service mesh) | istio-system | 20001 | **30102** | <http://localhost:30102> | token |
| Jaeger (tracing) | observability | 16686 | **30103** | <http://localhost:30103> | none |
| OpenSearch Dashboards | logging | 5601 | **30104** | <http://localhost:30104> | admin |
| **Ledger app ACTIVE** | demo | 8080 | **31000** | <http://localhost:31000/books> | none |
| **Ledger app PREVIEW** | demo | 8080 | **31100** | <http://localhost:31100/books> | none |
| ArgoCD | argocd | 8080 (https) | **32000** | <https://localhost:32000> | `admin` / see command below |
| Jenkins | jenkins | 8080 | **32001** | <http://localhost:32001> | initial password |
| Falcosidekick UI | default | 2802 | **32100** ¹ | <http://localhost:32100> | `admin` / `admin` |
| Vault UI | default | 8200 | **32101** | <http://localhost:32101> | token `root` (dev mode) |
| SonarQube | sonarqube | 9000 | **32102** | <http://localhost:32102> | `admin` / `admin` |
| Kubernetes Dashboard | kubernetes-dashboard | 443 (https) | **32103** | <https://localhost:32103> | token |

¹ The instructor's notes use **31000** for Falcosidekick, but 31000 is also the ledger app. Use **32100** so both can run at the same time.

> The "Service port" column is the usual default for that tool. Always check yours with
> `kubectl get svc -n <namespace>` before exposing it.

### How to put a tool on its port (same 2 commands for every tool)

```bash
# 1) Create a NodePort copy of the tool's service (example: Grafana)
kubectl expose service grafana --type=NodePort --target-port=3000 --name=grafana-np -n monitoring

# 2) Pin it to the port from the table (no "kubectl edit" needed)
kubectl patch svc grafana-np -n monitoring --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30100}]'
```

```bash
# More examples, same pattern
kubectl expose service prometheus-server --type=NodePort --target-port=9090 --name=prometheus-server-np -n monitoring
kubectl patch svc prometheus-server-np -n monitoring --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30000}]'

kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
kubectl patch svc argocd-server -n argocd --type=json -p '[{"op":"replace","path":"/spec/ports/1/nodePort","value":32000}]'   # ports[1] = https

kubectl expose service falco-falcosidekick-ui --type=NodePort --target-port=2802 --name=falcosidekick-ui-np
kubectl patch svc falcosidekick-ui-np --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":32100}]'

kubectl expose service vault --type=NodePort --target-port=8200 --name=vault-ui-np
kubectl patch svc vault-ui-np --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":32101}]'
```

### Passwords

```bash
# Grafana admin password
kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo

# ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d ; echo
```

### Which ports are used right now?

```bash
# Every NodePort in the cluster -> look at the PORT(S) column, e.g. 80:30100/TCP
kubectl get svc -A | grep NodePort

# Check one port before using it (no output = free)
kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{"\n"}{end}' | tr ' ' '\n' | grep -x 30100
```

> ❗ **Error `provided port is already allocated`** = another service already has that NodePort.
> Pick a free one from the same group.
> ❗ **Port works in the cluster but not in the browser** = that port is not in `kind-config.yaml`
> (only the 122 ports above are open on the laptop).

---

## 0. Install tools (one time per machine)

```bash
# --- Basic packages ---
# jq + openssl: Vault step | unzip: AWS CLI | gettext-base: gives "envsubst" (ECR secret template)
sudo apt update
sudo apt install -y curl git jq openssl unzip gettext-base
```

```bash
# --- Docker (Kind runs every Kubernetes node as a Docker container) ---
sudo apt install -y docker.io
sudo usermod -aG docker $USER     # lets you run docker without sudo
newgrp docker                     # apply the group now (or log out / log in)
docker ps                         # must work WITHOUT sudo
```

```bash
# --- kubectl (latest stable) ---
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
kubectl version --client
```

```bash
# --- kind ---
# FIX: the lab uses v0.20.0, which is too old for Kubernetes 1.35 node images. Use a current release.
# (Latest releases: https://github.com/kubernetes-sigs/kind/releases)
KIND_VERSION=v0.33.0
sudo curl -Lo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
sudo chmod +x /usr/local/bin/kind
kind version
```

```bash
# --- Helm ---
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

```bash
# --- AWS CLI v2 ---
# FIX: installs to the DEFAULT place (/usr/local/bin/aws). The lab installs to /usr/bin,
# that's why its commands say "/usr/bin/aws". In this guide we just type "aws".
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -o awscliv2.zip
sudo ./aws/install --update
aws --version
cd -
```

```bash
# --- Optional: Terraform shortcut "tf" (saved forever in ~/.bashrc) ---
echo -e '\n# Terraform shortcut\nalias tf=terraform' >> ~/.bashrc
source ~/.bashrc        # needed only in terminals that were ALREADY open
```


### ⚙️ Raise the **inotify** limits (do this BEFORE creating the kind cluster)

**What is inotify?** The Linux feature that lets programs *watch files for changes*.
Every kind node is a container sharing the laptop's kernel, and each one runs systemd, kubelet,
containerd... which all use inotify. **Fluent Bit / Promtail / Alloy** also use it to tail every
log file. Ubuntu's default limit is small, so with many nodes and log tools pods crash with
**`too many open files`** or **`failed to create fsnotify watcher`**.

```bash
# Check current values
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
```

```bash
# Raise them PERMANENTLY (file survives reboot), then load it now
# 8192 instances / 1M watches = safe for a big lab (11 nodes + monitoring + Fluent Bit + Falco)
# kind's minimum recommendation is 512 / 524288
sudo tee /etc/sysctl.d/99-kind.conf <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
EOF
sudo sysctl --system | grep inotify
```

---

## 1. AWS credentials

```bash
# Saves keys in ~/.aws/credentials, so every terminal, Terraform and the AWS CLI can use them.
# FIX: do this instead of "export AWS_ACCESS_KEY_ID=..." lines from the lab.
#      Never paste real keys into notes, chats or Git.
aws configure
#   AWS Access Key ID     : <your IAM user key>   (NOT root account keys)
#   AWS Secret Access Key : <your secret>
#   Default region name   : us-east-1
#   Default output format : json

aws sts get-caller-identity     # shows your account ID = it works
```

> Only use `export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...` when there is no `~/.aws`
> (CI pipeline, Docker container, `sudo`) or to switch accounts temporarily. Env vars win over the file.

---

## 2. Create the Kind cluster (no default CNI)

```bash
# Clone the lab repo (private: GitHub will ask for username + Personal Access Token)
git clone https://github.com/wezva-fintech/k8s-ledger-mysql.git deployments
```

```bash
# Name of the cluster. Node names become <CLUSTER>-control-plane, <CLUSTER>-worker, <CLUSTER>-worker2 ...
CLUSTER=wezvatechprod
```

**Option A: the lab's config** (`deployments/kindcluster.yml`):

```bash
# IMPORTANT: check the pod subnet first. It MUST match the Calico cidr in step 3.
grep -nE 'disableDefaultCNI|podSubnet' deployments/kindcluster.yml
kind create cluster --name $CLUSTER --config deployments/kindcluster.yml
```

**Option B: my tested config** (1 control-plane + **10 workers**, no kindnet, pod subnet `10.244.0.0/16`, **122 ports**):

| Host ports | Use |
|---|---|
| 80, 443 | Ingress. Unlimited tools by hostname, e.g. `grafana.localhost` |
| 30000-30019 | General use (lab: 30000 = Prometheus) |
| 30100-30119 | Observability UIs (lab: 30100 = Grafana) |
| 31000-31019 | Apps ACTIVE (lab: 31000 = ledger active / Falcosidekick UI) |
| 31100-31119 | Apps PREVIEW (lab: 31100 = ledger preview) |
| 32000-32019 | CD / GitOps tools (lab: 32000 = ArgoCD) |
| 32100-32119 | Security tools + spare |

```bash
# Ports 80/443 must be free on the machine (stop any web server first)
sudo ss -ltnp | grep -E ':(80|443) ' && echo "STOP what is using 80/443 first (e.g. sudo systemctl stop nginx)"
```

```bash
# Generates kind-config.yaml (10 workers, 122 port mappings), then creates the cluster.
{
cat <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true        # no kindnet; we install Calico ourselves
  podSubnet: "10.244.0.0/16"     # MUST match Calico IPPool cidr (step 3)
                                 # NOT 192.168.0.0/16: clashes with home Wi-Fi 192.168.0.x
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80,  hostPort: 80,  protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
EOF
# 6 groups x 20 NodePorts
for start in 30000 30100 31000 31100 32000 32100; do
  for p in $(seq $start $((start+19))); do
    echo "      - { containerPort: $p, hostPort: $p, protocol: TCP }"
  done
done
# 10 worker nodes
for i in $(seq 1 10); do echo "  - role: worker"; done
} > kind-config.yaml

grep -c hostPort kind-config.yaml      # must print 122
kind create cluster --name $CLUSTER --config kind-config.yaml
```

> **How the ports work:** browser → `localhost:<port>` → kind control-plane container → kube-proxy →
> Service with `type: NodePort` + `nodePort: <port>` → your pod on **any** node.
> Ports can't be added to a running kind cluster: edit the config + recreate.

```bash
# Nodes show "NotReady". That is NORMAL until Calico is installed (no CNI yet).
kubectl get nodes
```

---

## 3. Install Calico CNI

```bash
# Operator (use "create", not "apply": its CRDs are too big for client-side apply)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/tigera-operator.yaml
```

```bash
# FIX: the lab's custom-resources.yaml uses cidr 192.168.0.0/16.
# If that doesn't match the kind podSubnet, Calico creates NO pods (silent failure).
# This version uses 10.244.0.0/16 = same as kind-config.yaml above.
cat > calico-custom-resources.yaml <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:                       # cannot be changed after install
    - blockSize: 26
      cidr: 10.244.0.0/16          # MUST equal kind podSubnet
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

kubectl apply -f calico-custom-resources.yaml
```

```bash
# Wait until all calico-system pods are Running and all nodes are Ready (2-4 min). Ctrl+C to stop watching.
kubectl get pods -n calico-system --watch
kubectl get nodes
kubectl get tigerastatus          # calico + apiserver should be AVAILABLE=True
```

---

## 4. Install Vault + store DB secret and SSL cert

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault --set "server.dev.enabled=true"   # dev mode = lab only
# ⚠️ Dev mode keeps everything in RAM: if vault-0 restarts or the laptop reboots,
#    all secrets + auth config are LOST. Re-run this whole step 4 after a reboot.
kubectl get pods --watch          # wait for vault-0 1/1 Running, then Ctrl+C
```

```bash
# Self-signed SSL cert for the database (creates tls.key + tls.crt in current folder)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=database.demo.svc.cluster.local/O=WezvaTech"
```

```bash
# Store DB username/password in Vault
# (Same as the lab, but runs from your terminal, so there's no need to "exec -it" into the pod.)
kubectl exec vault-0 -- vault secrets enable -path=internal kv-v2
kubectl exec vault-0 -- vault kv put internal/database/config username="admin" password="wezvatech"
kubectl exec vault-0 -- vault kv get internal/database/config
```

```bash
# Store the SSL cert + key in Vault
jq -n --arg cert "$(<tls.crt)" --arg key "$(<tls.key)" '{"tls.crt": $cert, "tls.key": $key}' \
  | kubectl exec -i vault-0 -- vault kv put internal/database/ssl -

# FIX: the lab reads this BEFORE writing it. Read it AFTER:
kubectl exec vault-0 -- vault kv get internal/database/ssl
```

```bash
# Let pods log in to Vault with their Kubernetes ServiceAccount
kubectl exec vault-0 -- vault auth enable kubernetes
kubectl exec vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"

# Policy: allow READ on the two secrets
kubectl exec -i vault-0 -- vault policy write wezvatech-admin - <<'EOF'
path "internal/data/database/config" {
   capabilities = ["read"]
}
path "internal/data/database/ssl" {
   capabilities = ["read"]
}
EOF

# Role: ServiceAccount "wezvatech-admin" in namespace "demo" gets that policy
kubectl exec vault-0 -- vault write auth/kubernetes/role/wezvatech-admin \
    bound_service_account_names=wezvatech-admin \
    bound_service_account_namespaces=demo \
    policies=wezvatech-admin \
    ttl=24h
```

---

## 5. Install Argo Rollouts

```bash
kubectl create namespace argo-rollouts

# FIX: plain "kubectl apply" fails with "metadata.annotations: Too long".
# The Rollout CRDs are bigger than the 256 KB limit, so use --server-side.
kubectl apply --server-side --force-conflicts -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl get pods -n argo-rollouts --watch     # 1 controller pod is normal
```

```bash
# kubectl plugin: "kubectl argo rollouts ..."
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
kubectl argo rollouts version
```

---

## 6. ECR image pull secret

The kind cluster is not in AWS, so it can't use IAM roles to pull from private ECR.
We give it a **username (`AWS`) + password (temporary ECR token)** stored in a Kubernetes secret.

```bash
# Variables used to build the secret. "export" is needed so envsubst can see them.
export REGION=us-east-1          # region of your ECR repo
export ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text)
export TOKEN=$(aws ecr get-authorization-token --region $REGION --output text \
  --query 'authorizationData[0].authorizationToken' | base64 -d | cut -d: -f2)

echo $ACCOUNT        # 12-digit account ID
echo ${#TOKEN}       # token length: a big number (~2000+)
```

```bash
# Template file: placeholders only, real token is NEVER saved on disk
cat > ecr-secret.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: v1
kind: Secret
metadata:
  name: ecr-secret
  namespace: demo
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com": {
          "username": "AWS",
          "password": "${TOKEN}"
        }
      }
    }
EOF

# Fill in the placeholders and create namespace "demo" + secret "ecr-secret"
envsubst < ecr-secret.yaml | kubectl apply -f -
kubectl get secret ecr-secret -n demo
```

> ⏰ **The ECR token expires after 12 hours.** If pods show `ImagePullBackOff` later,
> re-run the `export` block, then `envsubst < ecr-secret.yaml | kubectl apply -f -`.

<details>
<summary>Same thing with the lab's one-line command (instead of the YAML)</summary>

```bash
kubectl create ns demo
kubectl create secret docker-registry ecr-secret -n demo \
   --docker-server=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com \
   --docker-username=AWS \
   --docker-password="$TOKEN"
```
</details>

---

## 7. Vault Secrets Operator

```bash
# Syncs secrets from Vault into Kubernetes secrets for the app
helm install vault-secrets-operator hashicorp/vault-secrets-operator
kubectl get crd | grep vault
```

---

## 8. Network policies + deploy the Ledger app

```bash
cd deployments/policies
kubectl apply -f . -n demo
cd -
```

```bash
# FIX: the lab hard-codes "wezvatechprod-worker". The node name depends on YOUR cluster name.
kubectl get nodes
kubectl label nodes ${CLUSTER}-worker disktype=ssd --overwrite
```

**Before deploying, edit 2 files in `deployments/springboot/`:**
- `dbservice.yml`: put your **RDS endpoint** (e.g. `aws rds describe-db-instances --query 'DBInstances[].Endpoint.Address' --output text`)
- `deployment.yml`: put your **ECR image** (`<ACCOUNT>.dkr.ecr.<REGION>.amazonaws.com/<repo>:<tag>`) and `MSK_BOOTSTRAP_SERVERS`

```bash
cd deployments/springboot
kubectl apply -f . -n demo
kubectl argo rollouts get rollout wezvaspringbootapp -n demo --watch
```

```bash
# Useful during the blue-green test
kubectl get pods -n demo
kubectl exec -it -c main <podname> -n demo -- /bin/sh               # shell inside app container
kubectl argo rollouts promote wezvaspringbootapp -n demo             # preview -> active
kubectl argo rollouts undo wezvaspringbootapp -n demo --to-revision=1  # rollback
```

**Open the app** (on a laptop, `<kind-server-ip>` = `localhost`; on EC2 use the public IP + open the ports in the security group):
- Active: <http://localhost:31000/books>
- Preview: <http://localhost:31100/books>

> **Blue-green test:** change the image tag in `deployment.yml`, `kubectl apply -f . -n demo`,
> check the preview port, then `promote`.

---

## 9. Autoscaling (metrics-server + HPA)

```bash
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# FIX: instead of editing line 135 by hand, add --kubelet-insecure-tls with one command
# (kind nodes use self-signed kubelet certs)
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

```bash
# Wait for v1beta1.metrics.k8s.io = True (Ctrl+C), then check metrics
kubectl get apiservices v1beta1.metrics.k8s.io --watch
kubectl top nodes
```

```bash
# Apply the HPA from the lab repo
cd deployments/springboot/autoscaling
kubectl apply -f hpa.yml -n demo
kubectl get hpa -n demo --watch
cd -
```

---

## 10. Cleanup

```bash
kind get clusters
kind delete cluster --name $CLUSTER
```

```bash
# AWS resources cost money: destroy them when the lab is done
# (run inside each Terraform folder, e.g. RDS / ECR / MSK)
terraform destroy -auto-approve
```

---

## Troubleshooting: errors I already hit

| Error / symptom | Cause | Fix |
|---|---|---|
| Nodes `NotReady`, CoreDNS `Pending` right after `kind create` | `disableDefaultCNI: true`, so there's no network yet | Normal. Install Calico (step 3) |
| `kubectl get pods -n calico-system` shows **nothing** | Calico `cidr` ≠ kind `podSubnet`. Check with `kubectl get tigerastatus calico -o yaml` → `IPPool ... is not within ... pod network CIDR` | Make both the same (`10.244.0.0/16`). `kubectl delete installation default`, then re-apply step 3 YAML |
| `metadata.annotations: Too long: may not be more than 262144 bytes` | CRD too big for client-side `kubectl apply` | Add `--server-side --force-conflicts` |
| `missing the kubectl.kubernetes.io/last-applied-configuration annotation` | Object was made with `create`, now using `apply` | Harmless warning, only shows once |
| `bash: /usr/bin/aws: No such file or directory` | AWS CLI is in `/usr/local/bin` | Type `aws` (no path) |
| `tf: command not found` right after adding the alias | Terminal was open before `~/.bashrc` changed | `source ~/.bashrc` (don't `apt install tf`, it's a different program) |
| Pods `ImagePullBackOff` from ECR | ECR token expired (12 h) or wrong region | Re-run step 6 |
| RDS: `Cannot find version 8.0.41 for mysql` | AWS retired that version | `aws rds describe-db-engine-versions --engine mysql --region <region> --query 'DBEngineVersions[].EngineVersion' --output text`, pick one listed (8.4.x = LTS) |
| Pods crash with `too many open files` / `failed to create fsnotify watcher` (kube-proxy, Fluent Bit, Promtail) | inotify limits too low for many kind nodes + log tools | Raise inotify (step 0), then `kubectl delete pod <pod>` to restart it |
| Vault secrets/config **gone** after restart / reboot | Vault runs in **dev mode** = stores everything in RAM | Re-run step 4 (all of it) |
| App not reachable on `localhost:31000` | Port not in kind `extraPortMappings` | Add it to the kind config and recreate the cluster (ports can't be added to a running kind cluster) |

### Quick health check

```bash
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed'     # anything listed here = problem
kubectl get tigerastatus
kubectl get pods -n argo-rollouts
kubectl get pods -n demo
```
