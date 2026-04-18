# WEKA Dedicated on Amazon EKS

Deploy WEKA client containers on EKS worker nodes connected to
a standalone WEKA backend storage cluster.

## Architecture

<!-- TODO: Add architecture diagram -->
<!-- ![Architecture](../img/weka-dedicated/architecture.png) -->

- **WEKA Backend**: 6+ i3en instances with NVMe storage
  ([terraform/weka-backend/](terraform/weka-backend/README.md))
- **EKS Cluster**: System nodes + WEKA client nodes
  ([terraform/eks/](terraform/eks/README.md))

## Prerequisites

- AWS CLI configured with appropriate permissions
- Existing VPC with subnets (private subnets recommended)
- Terraform >= 1.5
- kubectl, Helm 3.x
- WEKA download token from [get.weka.io](https://get.weka.io)
- Quay.io credentials for WEKA container images (available at
  [get.weka.io](https://get.weka.io))

## Directory Structure

The module is organized as:

- `terraform/`: Terraform for the WEKA backend and EKS cluster
- `manifests/`: Kubernetes manifests (WekaClient, CSI, test pods)
- `deploy.sh`: automated deployment script
- `generate-manifests.sh`: generates `weka-client.yaml` and CSI API
  secret from the deployed backend

```text
weka-dedicated/
├── terraform/
│   ├── weka-backend/    # WEKA storage cluster
│   └── eks/             # EKS cluster
├── manifests/           # Kubernetes manifests
│   ├── core/            # Required manifests (weka-client, CSI, etc.)
│   └── test/            # Test PVC and pod
├── generate-manifests.sh # Generate weka-client.yaml and CSI secret from backend
└── deploy.sh            # Automated deployment script
```

---

## Deploy Infrastructure

### 1. Deploy WEKA Backend

The backend module wraps the official
[WEKA AWS](https://registry.terraform.io/modules/weka/weka/aws/latest)
Terraform module. It creates an Auto Scaling group of instances
(with local NVMe for WEKA storage) and the IAM/Lambda
machinery that forms the WEKA cluster at boot.

Start by copying the example variables file:

```bash
cd terraform/weka-backend
cp terraform.tfvars.example terraform.tfvars
```

#### 1.1 Configure Terraform

Edit `terraform.tfvars`. Key variables:

- `region`
- `cluster_name` (tagged on all WEKA instances)
- `cluster_size` (minimum 6 for a valid WEKA cluster)
- `instance_type` (i3en or i8ge)
- `key_pair_name` (EC2 key pair for SSH)
- `get_weka_io_token` (from [get.weka.io](https://get.weka.io))
- `subnet_ids` (single AZ; all backend instances share one
  placement group)

See [terraform/weka-backend/README.md](terraform/weka-backend/README.md)
for the full variable reference.

#### 1.2 Terraform Deployment

Create the backend cluster (takes 10-15 minutes):

```bash
terraform init && terraform apply
```

You'll need the backend IPs and admin password in later steps.
Commands for both are shown at point of use.

#### 1.3 Verify Deployment

The WEKA backend ships with a status Lambda you can invoke to watch
cluster formation:

```bash
aws lambda invoke \
  --function-name weka-<cluster_name>-status-lambda \
  --payload '{"type": "progress"}' \
  --region <region> \
  --cli-binary-format raw-in-base64-out /dev/stdout 2>/dev/null | jq
```

During installation, instances download and install WEKA (takes a
few minutes). `summary.clusterized` is `false` while work is in
progress:

```json
{
  "ready_for_clusterization": null,
  "progress": {
    "ip-10-0-67-159.us-west-2.compute.internal": [
      "08:10:48 UTC: Downloading weka install script",
      "08:10:49 UTC: Installing weka"
    ],
    "ip-10-0-67-15.us-west-2.compute.internal": [
      "08:10:50 UTC: Downloading weka install script",
      "08:10:52 UTC: Installing weka"
    ]
  },
  "in_progress": [
    "ip-10-0-67-159.us-west-2.compute.internal",
    "ip-10-0-67-15.us-west-2.compute.internal"
  ],
  "summary": {
    "in_progress": 6,
    "clusterization_target": 6,
    "clusterized": false
  }
}
```

Once clusterization completes, `summary.clusterized` flips to
`true` and the designated "Clusterization" instance shows the
full bootstrap log:

```json
{
  "ready_for_clusterization": null,
  "progress": {
    "ip-10-0-67-159.us-west-2.compute.internal": [
      "08:10:48 UTC: Downloading weka install script",
      "08:10:49 UTC: Installing weka",
      "08:12:46 UTC: Weka software installation completed",
      "08:13:22 UTC: Weka containers are ready",
      "08:13:24 UTC: This (i-0900eefb0731eed34) is instance 3/6 that is ready for clusterization"
    ],
    "ip-10-0-67-15.us-west-2.compute.internal": [
      "08:11:14 UTC: Downloading weka install script",
      "08:11:15 UTC: Installing weka",
      "08:13:09 UTC: Weka software installation completed",
      "08:13:39 UTC: Weka containers are ready",
      "08:13:43 UTC: This (i-014f09587d90b25d4) is instance 6 that is ready for clusterization",
      "08:13:44 UTC: Running Clusterization",
      "08:14:42 UTC: Adding drives",
      "08:16:10 UTC: Running start-io",
      "08:16:59 UTC: Clusterization completed successfully",
      "08:17:01 UTC: Skipping OBS setup"
    ]
  },
  "in_progress": null,
  "summary": {
    "in_progress": 0,
    "clusterization_target": 6,
    "clusterized": true
  }
}
```

You can start deploying the EKS cluster while this is in progress,
but `clusterized` should be `true` before you install the WEKA
operator.

### 2. Deploy EKS Cluster

Provision the EKS control plane and node groups with Terraform.
Start by copying the example variables file:

```bash
cd ../eks
cp terraform.tfvars.example terraform.tfvars
```

#### 2.1 Configure Terraform

Edit `terraform.tfvars`. Key variables:

- `region`
- `cluster_name`
- `subnet_ids`: place the `clients` group in the same subnet as the
  WEKA backend (single placement group / AZ)
- `admin_role_arn` (IAM role for cluster admin access)
- `enable_ssm_access` (enabled by default for node debugging)
- `hugepages_count`: set **per node group**. See
  [section 2.1](#21-hugepages) for the sizing formula.

See [terraform/eks/README.md](terraform/eks/README.md) for the full
variable reference.

#### 2.2 Node Groups

The client node group uses a label + taint pattern:

- **Label** `weka.io/supports-clients=true`: positive selector so
  WEKA-aware workloads (operator node-agent, WEKA client containers,
  CSI plugin) know which nodes to land on.
- **Taint** `weka.io/client=true:NoSchedule`: prevents non-WEKA
  workloads from scheduling on these nodes and impacting WEKA or
  application performance. Anything that needs to run here must
  explicitly tolerate the taint.

```hcl
node_groups = {
  system = {
    instance_types = ["m6i.large"]
    desired_size   = 2
    min_size       = 2
    max_size       = 2
    labels = {
      "node-role" = "system"
    }
  }

  clients = {
    instance_types            = ["c6i.12xlarge"]
    desired_size              = 2
    min_size                  = 1
    max_size                  = 4
    subnet_ids                = ["subnet-xxx"]
    imds_hop_limit_2          = true
    enable_cpu_manager_static = true
    disable_hyperthreading    = true
    core_count                = 24
    hugepages_count           = 2048
    labels = {
      "weka.io/supports-clients" = "true"
    }
    taints = [{
      key    = "weka.io/client"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
}
```

#### 2.3 Terraform Deployment

Create the EKS cluster (takes about 10-15 minutes):

```bash
terraform init && terraform apply

# Configure kubectl
$(terraform output -raw configure_kubectl)
cd ../..
```

Confirm all nodes are `Ready`:

```bash
kubectl get nodes

NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-0-217.us-west-2.compute.internal    Ready    <none>   45m   v1.33.8-eks-f69f56f
ip-10-0-10-91.us-west-2.compute.internal    Ready    <none>   45m   v1.33.8-eks-f69f56f
ip-10-0-7-51.us-west-2.compute.internal     Ready    <none>   45m   v1.33.8-eks-f69f56f
ip-10-0-10-165.us-west-2.compute.internal   Ready    <none>   45m   v1.33.8-eks-f69f56f
```

Verify WEKA client nodes are labeled:

```bash
kubectl get nodes -l weka.io/supports-clients=true

NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-10-91.us-west-2.compute.internal    Ready    <none>   5m    v1.33.8-eks-f69f56f
ip-10-0-10-165.us-west-2.compute.internal   Ready    <none>   5m    v1.33.8-eks-f69f56f
```

---

## Automated Kubernetes Setup

Once the Terraform modules are applied, `deploy.sh` handles
everything else: manifest generation, operator install, ensure-nics,
WekaClient, CSI plugin, StorageClass, and a test pod.

If you'd rather walk through each step by hand, skip to
[Manual Kubernetes Setup](#manual-kubernetes-setup).

```bash
./deploy.sh \
  --cluster-name my-eks-cluster \
  --quay-username myuser \
  --quay-password mypass \
  --backend-name eks-storage-cluster \
  --secret-arn arn:aws:secretsmanager:us-west-2:123456:secret:weka/...
```

When `--backend-name` and `--secret-arn` are provided, the script
runs `generate-manifests.sh` internally to produce `weka-client.yaml`
and `csi-wekafs-api-secret.yaml` from the backend's IPs and Secrets
Manager password. If you've already generated the manifests
manually, omit those two flags.

All flags can alternatively be set via environment variables:

| Flag | Environment Variable | Description |
| ---- | -------------------- | ----------- |
| `--cluster-name` | `CLUSTER_NAME` | EKS cluster name |
| `--quay-username` | `QUAY_USERNAME` | Quay.io username |
| `--quay-password` | `QUAY_PASSWORD` | Quay.io password |
| `--backend-name` | `WEKA_BACKEND_NAME` | WEKA backend tag (auto-generates manifests) |
| `--secret-arn` | `WEKA_SECRET_ARN` | Secrets Manager ARN for WEKA password |
| `--region` | `AWS_REGION` | AWS region |
| `--operator-version` | `WEKA_OPERATOR_VERSION` | Operator chart version (default: `v1.11.0`) |

Run `./deploy.sh --help` for all options.

To regenerate manifests standalone (e.g. for manual review before
deploy), run `./generate-manifests.sh --help`.

Once `deploy.sh` finishes, head to
[Verify WEKA Processes](#4-verify-weka-processes) to check the
cluster and running processes.

See [Cleanup](#cleanup) for teardown instructions.

---

## Manual Kubernetes Setup

All commands assume you are in the `weka-dedicated/` directory.

### 1. Deploy WEKA Operator

The [WEKA Operator](https://docs.weka.io/kubernetes/weka-operator-deployments)
manages WEKA storage components via Kubernetes Custom Resources
(WekaClient, WekaPolicy). The standalone CSI plugin is installed
separately in a later step.

Create the namespace:

```bash
kubectl create namespace weka-operator-system
```

Create the Quay pull secret:

```bash
kubectl create secret docker-registry weka-quay-io-secret \
  --namespace weka-operator-system \
  --docker-server=quay.io \
  --docker-username=<QUAY_USERNAME> \
  --docker-password=<QUAY_PASSWORD>
```

Install the operator:

```bash
helm upgrade --install weka-operator \
  oci://quay.io/weka.io/helm/weka-operator \
  --namespace weka-operator-system \
  --version v1.11.0 \
  --set imagePullSecret=weka-quay-io-secret \
  -f manifests/core/values-weka-operator.yaml \
  --wait
```

Output:

```bash
Release "weka-operator" does not exist. Installing it now.
Pulled: quay.io/weka.io/helm/weka-operator:v1.11.0
Digest: sha256:646b7ab0f71b170ba8be24b44af08ae04f261034c66cbca451478211e614e854
NAME: weka-operator
LAST DEPLOYED: Mon Apr 13 09:05:43 2026
NAMESPACE: weka-operator-system
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None
NOTES:
Chart: weka-operator
Release: weka-operator
```

Verify the pods have deployed:

```bash
kubectl get pods -n weka-operator-system

NAME                                                READY   STATUS    RESTARTS   AGE
weka-operator-controller-manager-7977d977fd-hwsxc   2/2     Running   0          81s
weka-operator-node-agent-2pwsb                      1/1     Running   0          82s
weka-operator-node-agent-489fr                      1/1     Running   0          82s
```

You should see one `controller-manager` pod (on system nodes) and
one `node-agent` per WEKA node.

### 2. Prepare Client Nodes

#### 2.1 Hugepages

WEKA uses 2 MiB hugepages for client container processes. The node
must have enough total hugepages to cover every container that
will run on it. Each container's request includes a base allocation
plus a DPDK memory component and an offset.

**Per-container formula:**

| Container | Hugepages (MiB) | Offset (MiB) |
| --------- | --------------- | ------------ |
| Client | `(1500 * clientCores) + (64 * clientCores)` | `200 + (64 * clientCores)` |

Each pod requests `hugepages + offset` from the node pool.

Walking through the container for c6i.12xlarge (2 client cores):

- **Client**: hugepages `(1500 × 2) + (64 × 2) = 3128`, offset
  `200 + (64 × 2) = 328` → **3456 MiB** pod request.

| Container | Pod request |
| --------- | ----------- |
| Client | 3456 MiB |
| **Per-node total** | **3456 MiB** |

Convert to pages: `3456 / 2 = 1728 pages`. Round up with ~20%
headroom to a multiple of 1024: **2048 pages** (4096 MiB).

Set this in `terraform.tfvars`:

```hcl
hugepages_count = 2048
```

Hugepages are configured at node boot via the launch template
user data.

Verify allocation after nodes are running:

```bash
kubectl get nodes -l weka.io/supports-clients=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi

NAME                                        HUGEPAGES
ip-10-0-10-91.us-west-2.compute.internal    4Gi
ip-10-0-10-165.us-west-2.compute.internal   4Gi
```

#### 2.2 Configure NICs

WEKA uses [DPDK](https://docs.weka.io/weka-system-overview/networking-in-wekaio)
for high-performance networking, which requires dedicated ENIs
per WEKA process. The `ensure-nics` WekaPolicy creates and attaches
additional ENIs to each node.

`dataNICsNumber` = `coresNum + 1`: one NIC per WEKA process plus
one for the EKS VPC CNI. For this guide's 2-core client, that's
3 secondary NICs (plus 1 primary management NIC = 4 total). The
policy creates the secondary NICs if they're missing.

Review `manifests/core/ensure-nics.yaml`:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaPolicy
metadata:
  name: ensure-nics-policy
  namespace: weka-operator-system
spec:
  type: "ensure-nics"
  image: "quay.io/weka.io/weka-in-container:4.4.21.2"
  imagePullSecret: "weka-quay-io-secret"
  payload:
    ensureNICsPayload:
      type: aws
      nodeSelector:
        weka.io/supports-clients: "true"
      dataNICsNumber: 3
```

Apply the policy:

```bash
kubectl apply -f manifests/core/ensure-nics.yaml
```

Wait for completion:

```bash
kubectl get wekapolicies -n weka-operator-system -w
```

Wait until `STATUS` shows `Done`:

```text
NAME                 TYPE          STATUS   PROGRESS
ensure-nics-policy   ensure-nics   Done
```

### 3. Deploy WEKA Client

The `WekaClient` CR creates frontend processes that provide POSIX
access to the cluster. In a dedicated deployment, clients connect
to an external WEKA backend via `joinIpPorts`.

Get the backend IPs for `joinIpPorts`:

```bash
# Uses wildcard match. WEKA names instances <prefix>-<cluster_name>-instance-backend
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*<cluster_name>*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '\t' '\n'

10.0.67.159
10.0.67.15
10.0.66.95
10.0.65.82
10.0.64.194
10.0.67.69
```

Copy and edit the example manifest:

```bash
cp manifests/core/weka-client.yaml.example manifests/core/weka-client.yaml
```

Review `manifests/core/weka-client.yaml` and fill in your configuration:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaClient
metadata:
  name: weka-client
  namespace: weka-operator-system
spec:
  coresNum: 2
  driversDistService: "https://drivers.weka.io"
  hugepages: 3072
  image: quay.io/weka.io/weka-in-container:4.4.21.2
  imagePullSecret: weka-quay-io-secret
  joinIpPorts:
    - "10.0.67.159:14000"
    - "10.0.67.15:14000"
    - "10.0.66.95:14000"
    - "10.0.65.82:14000"
    - "10.0.64.194:14000"
    - "10.0.67.69:14000"
  network:
    udpMode: false
  nodeSelector:
    weka.io/supports-clients: "true"
  portRange:
    basePort: 46000
  rawTolerations:
    - key: "weka.io/client"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
```

Key fields:

- `spec.coresNum`: cores for the client process
- `spec.joinIpPorts`: IPs + port 14000 for the external WEKA backend
- `spec.rawTolerations`: allows scheduling on tainted client nodes

Apply:

```bash
kubectl apply -f manifests/core/weka-client.yaml
```

Verify the client has deployed:

```bash
kubectl get wekaclient -n weka-operator-system

NAME          STATUS    TARGET CLUSTER       CORES   CONTAINERS(A/C/D)
weka-client   Running   weka-eks-cluster     2       2/2/2
```

`CONTAINERS(A/C/D)` shows Active/Created/Desired. All should
match when ready.

### 4. Verify WEKA Processes

#### 4.1 Client Verification

List the WEKA client pods:

```bash
kubectl get pods -n weka-operator-system -o wide | grep -i client

weka-client-ip-10-0-10-91.us-west-2.compute.internal     1/1     Running   0    3m3s   10.0.10.91    ip-10-0-10-91.us-west-2.compute.internal    <none>   <none>
weka-client-ip-10-0-10-165.us-west-2.compute.internal    1/1     Running   0    3m3s   10.0.10.165   ip-10-0-10-165.us-west-2.compute.internal   <none>   <none>
```

Pick one and run `weka local ps` inside its `weka-container`:

```bash
kubectl exec -n weka-operator-system weka-client-ip-10-0-10-91.us-west-2.compute.internal -c weka-container -- \
  bash -lc 'weka local ps'

CONTAINER           STATE    DISABLED  UPTIME    MONITORING  PERSISTENT   PORT  PID  STATUS  VERSION     LAST FAILURE
a1b2c3d4e5f6client  Running  True      0:04:32h  True        True        46001  822  Ready   4.4.21.2
```

#### 4.2 Access WEKA Web UI

The WEKA web UI is available on port 14000 of any backend IP
(or the ALB if configured). If the backend is in a private subnet,
you may need port forwarding or a bastion host.

Retrieve the admin password from Secrets Manager (the command is
shown in the `terraform output` of the weka-backend module).

Verify clients appear under the Clients section with status "UP":

![WEKA Clients](../img/weka-dedicated/weka-clients.png)

### 5. WEKA CSI Plugin

Start by creating a namespace for the CSI plugin:

```bash
kubectl create namespace csi-wekafs
```

#### 5.1 Create API Secret

Copy and edit the example manifest:

```bash
cp manifests/core/csi-wekafs-api-secret.yaml.example manifests/core/csi-wekafs-api-secret.yaml
```

The secret requires these fields, all **base64 encoded**:

| Field | Value |
| ----- | ----- |
| `username` | `admin` (default) |
| `password` | Retrieved from Secrets Manager (see below) |
| `scheme` | `https` |
| `endpoints` | Backend IPs with port 14000, comma-separated |
| `organization` | `Root` |

Retrieve the admin password:

```bash
cd terraform/weka-backend
terraform output -json weka_deployment_output \
  | jq -r '.cluster_helper_commands.get_password' | bash
cd ../..

<admin-password>
```

To base64 encode a value:

```bash
echo -n 'your-value' | base64
```

Example encoded secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: csi-wekafs-api-secret
  namespace: csi-wekafs
type: Opaque
data:
  username: YWRtaW4=
  password: YWRtaW4tcGFzc3dvcmQ=
  scheme: aHR0cHM=
  endpoints: MTAuMC42Ny4xNTk6MTQwMDAsMTAuMC42Ny4xNToxNDAwMA==
  organization: Um9vdA==
```

Once you've entered the correct values, create the secret:

```bash
kubectl apply -f manifests/core/csi-wekafs-api-secret.yaml
```

You can use this command to check the values in the secret:

```bash
kubectl get secret csi-wekafs-api-secret -n csi-wekafs -o json | \
  jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

#### 5.2 Install CSI Plugin

Add the WEKA CSI helm repo:

```bash
helm repo add csi-wekafs https://weka.github.io/csi-wekafs
helm repo update
```

Review `manifests/core/values-csi-wekafs.yaml`:

```yaml
controllerPluginTolerations:
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "weka.io/client"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"

nodePluginTolerations:
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "weka.io/client"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"

controller:
  nodeSelector:
    weka.io/supports-clients: "true"

node:
  nodeSelector:
    weka.io/supports-clients: "true"

pluginConfig:
  allowInsecureHttps: true
```

Both the CSI controller and node DaemonSet need to run on **WEKA client
nodes**. The CSI controller performs local WEKA filesystem mounts for
volume operations, so it needs the WEKA client driver loaded on the
same node (not just API access to the backend).

The settings below tie into the label + taint we configured on the
client node group:

- **`controller.nodeSelector` + `node.nodeSelector`**: match the
  `weka.io/supports-clients=true` label so both components land on
  client nodes.
- **`controllerPluginTolerations` + `nodePluginTolerations`**:
  tolerate the `weka.io/client=true:NoSchedule` taint so they can
  actually schedule there.
- **`allowInsecureHttps`**: required when the WEKA backend uses
  self-signed SSL certificates.

Install the plugin:

```bash
helm install csi-wekafs csi-wekafs/csi-wekafsplugin \
  --namespace csi-wekafs \
  -f manifests/core/values-csi-wekafs.yaml \
  --wait
```

Verify pods are running:

```bash
kubectl get pods -n csi-wekafs

NAME                                     READY   STATUS    RESTARTS   AGE
csi-wekafs-controller-59965597b9-rvcmg   6/6     Running   0          2m40s
csi-wekafs-controller-59965597b9-zmk6b   6/6     Running   0          2m40s
csi-wekafs-node-654t7                    3/3     Running   0          2m40s
csi-wekafs-node-nfnh4                    3/3     Running   0          2m40s
```

You should see:

- Two controller pods (for HA)
- One node pod per labeled EKS node

Occasionally a `csi-wekafs-node` pod restarts in a loop during
initial deployment. Deleting the pod (`kubectl delete pod
csi-wekafs-node-<id> -n csi-wekafs`) lets the DaemonSet recreate
it cleanly.

#### 5.3 Create StorageClass

We'll create an additional StorageClass with `WaitForFirstConsumer` binding
mode. Review `manifests/core/storageclass-weka.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: storageclass-wekafs-dir-api
provisioner: csi.weka.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  volumeType: dir/v1
  filesystemName: default
  capacityEnforcement: HARD
  csi.storage.k8s.io/provisioner-secret-name: &secretName csi-wekafs-api-secret
  csi.storage.k8s.io/provisioner-secret-namespace: &secretNamespace csi-wekafs
  csi.storage.k8s.io/controller-publish-secret-name: *secretName
  csi.storage.k8s.io/controller-publish-secret-namespace: *secretNamespace
  csi.storage.k8s.io/controller-expand-secret-name: *secretName
  csi.storage.k8s.io/controller-expand-secret-namespace: *secretNamespace
  csi.storage.k8s.io/node-stage-secret-name: *secretName
  csi.storage.k8s.io/node-stage-secret-namespace: *secretNamespace
  csi.storage.k8s.io/node-publish-secret-name: *secretName
  csi.storage.k8s.io/node-publish-secret-namespace: *secretNamespace
```

Key parameters:

| Parameter             | Options                                        | Description                                                                                                |
|-----------------------|------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| `volumeBindingMode`   | `WaitForFirstConsumer` (default), `Immediate`  | `WaitForFirstConsumer` delays provisioning until a pod uses the PVC - better for topology-aware scheduling |
| `reclaimPolicy`       | `Delete` (default), `Retain`                   | `Delete` removes the volume when PVC is deleted; `Retain` keeps it                                         |
| `filesystemName`      | `default`                                      | WEKA filesystem to use for volumes                                                                         |
| `capacityEnforcement` | `HARD`, `SOFT`                                 | `HARD` enforces quota limits strictly                                                                      |

Make sure `provisioner-secret-name` and `provisioner-secret-namespace`
match your CSI secret.

Create the StorageClass:

```bash
kubectl apply -f manifests/core/storageclass-weka.yaml
```

Verify:

```bash
kubectl get storageclass | grep weka

storageclass-wekafs-dir-api   csi.weka.io   Delete   WaitForFirstConsumer   true   5s
```

### 6. Test Dynamic Provisioning

Deploy a test PVC and pods to verify the WEKA CSI integration.

#### 6.1 Create PVC

First create a namespace for our test application:

```bash
kubectl create namespace weka-test
```

A sample PVC is provided:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-wekafs-dir
  namespace: weka-test
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: storageclass-wekafs-dir-api
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
```

This creates a 10 GiB `ReadWriteMany` PVC in the
`weka-test` namespace.

Apply:

```bash
kubectl apply -f manifests/test/pvc.yaml
```

And check that it was created:

```bash
kubectl get pvc -n weka-test

NAME             STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS                  VOLUMEATTRIBUTESCLASS   AGE
pvc-wekafs-dir   Pending                                      storageclass-wekafs-dir-api   <unset>                 19s
```

Status is **PENDING** because of `WaitForFirstConsumer`. It will
bind once a pod references the PVC.

#### 6.2 Deploy Writer Pod

Deploy a pod that mounts the PVC and writes test data:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: weka-writer
  namespace: weka-test
spec:
  nodeSelector:
    weka.io/supports-clients: "true"
  tolerations:
    - key: "weka.io/client"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
  containers:
    - name: writer
      image: busybox:1.37.0
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
      command:
        - sh
        - -c
        - |
          echo "Hello from WEKA!" > /data/hello.txt
          ls -la /data
          cat /data/hello.txt
          sleep 3600
      volumeMounts:
        - name: weka-volume
          mountPath: /data
  volumes:
    - name: weka-volume
      persistentVolumeClaim:
        claimName: pvc-wekafs-dir
```

Deploy the application pod:

```bash
kubectl apply -f manifests/test/weka-writer.yaml
```

You can check that the application ran:

```bash
kubectl logs -n weka-test weka-writer

total 4
drwxrwxrwx    2 root     root          4096 Jan 12 12:00 .
drwxr-xr-x    1 root     root          4096 Jan 12 12:00 ..
-rw-r--r--    1 root     root            17 Jan 12 12:00 hello.txt
Hello from WEKA!
```

You can also now see that the PVC has been bound:

```bash
kubectl get pvc -n weka-test

NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                  VOLUMEATTRIBUTESCLASS   AGE
pvc-wekafs-dir   Bound    pvc-835773b4-c060-455d-94a4-ec2ee85987b9   10Gi       RWX            storageclass-wekafs-dir-api   <unset>                 9m36s
```

#### 6.3 Verify Shared Access (ReadWriteMany)

Verify persistence by deploying a second pod that reads the
same PVC from a different node:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: weka-reader
  namespace: weka-test
spec:
  nodeSelector:
    weka.io/supports-clients: "true"
  tolerations:
    - key: "weka.io/client"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
  containers:
    - name: reader
      image: busybox:1.37.0
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
      command:
        - sh
        - -c
        - |
          set -eux
          echo "Reading data written by another pod:"
          cat /data/hello.txt
          sleep 3600
      volumeMounts:
        - name: weka-volume
          mountPath: /data
  volumes:
    - name: weka-volume
      persistentVolumeClaim:
        claimName: pvc-wekafs-dir
```

Deploy the pod:

```bash
kubectl apply -f manifests/test/weka-reader.yaml
```

Verify both application pods are running:

```bash
kubectl get pods -n weka-test -o wide

NAME          READY   STATUS    RESTARTS   AGE   IP            NODE                                        NOMINATED NODE   READINESS GATES
weka-writer   1/1     Running   0          12m   10.0.10.218   ip-10-0-10-91.us-west-2.compute.internal    <none>           <none>
weka-reader   1/1     Running   0          14s   10.0.10.140   ip-10-0-10-165.us-west-2.compute.internal   <none>           <none>
```

Examine the logs from the reader pod:

```bash
kubectl logs -n weka-test weka-reader

+ echo 'Reading data written by another pod:'
Reading data written by another pod:
+ cat /data/hello.txt
Hello from WEKA!
+ sleep 3600
```

## Cleanup

### Remove WEKA Components

Quick option (matches `deploy.sh`):

```bash
./deploy.sh --cleanup --cluster-name my-eks-cluster
```

Or manually:

```bash
# Delete test namespace
kubectl delete namespace weka-test

# Delete custom StorageClass
kubectl delete storageclass storageclass-wekafs-dir-api

# Delete CSI plugin
helm uninstall csi-wekafs -n csi-wekafs
kubectl delete namespace csi-wekafs

# Delete WEKA clients
kubectl delete wekaclient -n weka-operator-system --all

# Delete ensure-nics policy
kubectl delete wekapolicy -n weka-operator-system --all

# Delete WEKA operator
helm uninstall weka-operator -n weka-operator-system
kubectl delete namespace weka-operator-system
```

### Destroy Infrastructure

```bash
# Run each from the module root (weka-dedicated/)
(cd terraform/eks && terraform destroy)
(cd terraform/weka-backend && terraform destroy)
```
