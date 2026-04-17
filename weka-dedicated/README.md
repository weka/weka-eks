# WEKA Dedicated on EKS

Deploy WEKA client containers on EKS worker nodes connected to
a standalone WEKA backend storage cluster.

## Architecture

<!-- TODO: Add architecture diagram -->
<!-- ![Architecture](../img/weka-dedicated/architecture.png) -->

- **WEKA Backend**: 6+ i3en instances with NVMe storage
  ([terraform/weka-backend/](terraform/weka-backend/README.md))
- **EKS Cluster**: System nodes + WEKA client nodes
  ([terraform/eks/](terraform/eks/README.md))
- **Networking**: WEKA clients connect to backend via dedicated
  NICs (DPDK) or primary interface (UDP)

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.5
- kubectl, Helm 3.x
- WEKA download token from [get.weka.io](https://get.weka.io)
- Quay.io credentials for WEKA container images (available at
  [get.weka.io](https://get.weka.io))

## Directory Structure

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

## Automated Deployment

Once the Terraform modules are applied, `deploy.sh` handles
everything else: manifest generation, operator install, ensure-nics,
WekaClient, CSI plugin, StorageClass, and a test pod.

If you'd rather walk through each step by hand, skip to
[Manual Deployment](#manual-deployment).

```bash
./deploy.sh \
  --cluster-name my-eks-cluster \
  --quay-username myuser \
  --quay-password mypass \
  --backend-name eks-storage-cluster \
  --secret-arn arn:aws:secretsmanager:eu-west-1:123456:secret:weka/...
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

See [Cleanup](#cleanup) for teardown instructions.

---

## Manual Deployment

All commands assume you are in the `weka-dedicated/` directory.

## 1. Deploy WEKA Backend

```bash
cd terraform/weka-backend
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
terraform init && terraform apply
```

See [terraform/weka-backend/README.md](terraform/weka-backend/README.md)
for configuration details.

Save these outputs for EKS configuration:

```bash
# Security group for EKS nodes (use in additional_security_group_ids)
terraform output -json weka_deployment_output | jq -r '.sg_ids[]'

# Get backend IPs for WekaClient configuration
# Uses wildcard match — WEKA names instances <prefix>-<cluster_name>-instance-backend
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*<cluster_name>*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '\t' '\n'
```

## 2. Deploy EKS Cluster

```bash
cd ../eks
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- Set `additional_security_group_ids` to include the WEKA backend security group
- Set `subnet_ids` on the clients group to the same subnet as the
  WEKA backend (single placement group / AZ)
- Configure WEKA client node group with required settings:

The client node group uses a label + taint pattern:

- **Label** `weka.io/supports-clients=true` — positive selector so
  WEKA-aware workloads (operator node-agent, WEKA client containers,
  CSI plugin) know which nodes to land on.
- **Taint** `weka.io/client=true:NoSchedule` — prevents non-WEKA
  workloads from scheduling on these (typically expensive) nodes.
  Anything that needs to run here must explicitly tolerate the taint.

```hcl
node_groups = {
  system = {
    instance_types = ["m6i.large"]
    desired_size   = 2
    min_size       = 1
    max_size       = 3
    disk_size      = 50
  }

  clients = {
    instance_types            = ["c6i.12xlarge"]
    desired_size              = 2
    min_size                  = 1
    max_size                  = 4
    subnet_ids                = ["subnet-xxx"] # Same AZ as WEKA backend
    imds_hop_limit_2          = true
    enable_cpu_manager_static = true
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

```bash
terraform init && terraform apply

# Configure kubectl
$(terraform output -raw configure_kubectl)
cd ../..
```

See [terraform/eks/README.md](terraform/eks/README.md) for configuration details.

## 3. Verify Nodes

```bash
kubectl get nodes
```

Expected output:

```text
NAME                                       STATUS   ROLES    AGE   VERSION
ip-10-0-0-217.eu-west-1.compute.internal   Ready    <none>   45m   v1.33.8-eks-f69f56f
ip-10-0-2-172.eu-west-1.compute.internal   Ready    <none>   45m   v1.33.8-eks-f69f56f
ip-10-0-7-51.eu-west-1.compute.internal    Ready    <none>   45m   v1.33.8-eks-f69f56f
ip-10-0-9-215.eu-west-1.compute.internal   Ready    <none>   45m   v1.33.8-eks-f69f56f
```

Verify WEKA client nodes are labeled:

```bash
kubectl get nodes -l weka.io/supports-clients=true
```

Expected output:

```text
NAME                                         STATUS   ROLES    AGE   VERSION
ip-10-0-1-59.eu-west-1.compute.internal      Ready    <none>   5m    v1.33.8-eks-f69f56f
ip-10-0-10-160.eu-west-1.compute.internal    Ready    <none>   5m    v1.33.8-eks-f69f56f
```

## 4. Deploy WEKA Operator

### 4.1 Create Namespace

```bash
kubectl create namespace weka-operator-system
```

### 4.2 Create Quay.io Pull Secret

```bash
kubectl create secret docker-registry weka-quay-io-secret \
  --namespace weka-operator-system \
  --docker-server=quay.io \
  --docker-username="YOUR_QUAY_USERNAME" \
  --docker-password="YOUR_QUAY_PASSWORD"
```

### 4.3 Install WEKA Operator

```bash
helm upgrade --install weka-operator \
  oci://quay.io/weka.io/helm/weka-operator \
  --namespace weka-operator-system \
  --version v1.11.0 \
  --set imagePullSecret=weka-quay-io-secret \
  -f manifests/core/values-weka-operator.yaml \
  --wait
```

### 4.4 Verify

```bash
kubectl get pods -n weka-operator-system
```

Expected output:

```text
NAME                                                READY   STATUS    RESTARTS   AGE
weka-operator-controller-manager-7977d977fd-hwsxc   2/2     Running   0          81s
weka-operator-node-agent-2pwsb                      1/1     Running   0          82s
weka-operator-node-agent-489fr                      1/1     Running   0          82s
```

## 5. Verify Hugepages

WEKA clients require 2 MiB hugepages. The operator requests
per client pod:

- Hugepages: `coresNum * (1500 + 64)` MiB
- Offset: `200 + 64 * coresNum` MiB
- Total pod request: hugepages + offset

For 2 cores: `2 * 1564 = 3128` + `328` = **3456 MiB** = 1728
pages. The `hugepages_count = 2048` (4096 MiB) in your terraform
provides headroom.

Hugepages are configured at node boot via the launch template
user data. Verify allocation:

```bash
kubectl get nodes -l weka.io/supports-clients=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi
```

Expected output:

```text
NAME                                        HUGEPAGES
ip-10-0-1-59.eu-west-1.compute.internal     4Gi
ip-10-0-10-160.eu-west-1.compute.internal   4Gi
```

## 6. Run ensure-nics

Creates dedicated network interfaces for WEKA's DPDK networking.

Edit `manifests/core/ensure-nics.yaml`:

- Set `dataNICsNumber` to `coresNum + 1` (accounts for the EKS VPC CNI interface)

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

## 7. Deploy WekaClient

Get the backend IPs for `joinIpPorts`:

```bash
# Uses wildcard match — WEKA names instances <prefix>-<cluster_name>-instance-backend
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*<cluster_name>*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '\t' '\n'
```

Copy and edit the example manifest:

```bash
cp manifests/core/weka-client.yaml.example manifests/core/weka-client.yaml
```

Edit `manifests/core/weka-client.yaml` with your configuration:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaClient
metadata:
  name: weka-client
  namespace: weka-operator-system
spec:
  image: quay.io/weka.io/weka-in-container:4.4.21.2
  imagePullSecret: weka-quay-io-secret
  driversDistService: "https://drivers.weka.io"
  portRange:
    basePort: 46000
  nodeSelector:
    weka.io/supports-clients: "true"
  rawTolerations:
    - key: "weka.io/client"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"

  # Backend IPs from Step 1 (port 14000 for management)
  joinIpPorts:
    - "10.0.67.159:14000"
    - "10.0.67.15:14000"
    - "10.0.66.95:14000"
    - "10.0.65.82:14000"
    - "10.0.64.194:14000"
    - "10.0.67.69:14000"

  # dataNICsNumber in ensure-nics should be coresNum + 1
  coresNum: 2

  # Formula: coresNum × 1564 MiB (1500 base + 64 DPDK per core)
  hugepages: 3072

  network:
    # false = DPDK mode
    # true = UDP mode
    udpMode: false
```

```bash
kubectl apply -f manifests/core/weka-client.yaml
```

Monitor deployment:

```bash
kubectl get wekacontainers -n weka-operator-system -w
```

Expected output when ready:

```text
NAME                                                    STATUS    MODE     MANAGEMENT IPS   NODE                                        AGE
weka-client-ip-10-0-1-59.eu-west-1.compute.internal     Running   client   10.0.1.59        ip-10-0-1-59.eu-west-1.compute.internal     2m43s
weka-client-ip-10-0-10-160.eu-west-1.compute.internal   Running   client   10.0.10.160      ip-10-0-10-160.eu-west-1.compute.internal   2m43s
```

Wait for all containers to show `STATUS: Running`.

Check overall status:

```bash
kubectl get wekaclient -n weka-operator-system
```

```text
NAME          STATUS    TARGET CLUSTER   CORES   CONTAINERS(A/C/D)
weka-client   Running                    2       2/2/2
```

`CONTAINERS(A/C/D)` shows Active/Created/Desired - all should match when ready.

### 7.1 Access WEKA Web UI

The WEKA web UI is available on port 14000 of any backend IP
(or the ALB if configured). If the backend is in a private subnet,
you may need port forwarding or a bastion host.

Retrieve the admin password from Secrets Manager (the command is
shown in the `terraform output` of the weka-backend module).

Verify clients appear under the Clients section with status "UP":

![WEKA Clients](../img/weka-dedicated/weka-clients.png)

## 8. Deploy WEKA CSI Plugin

### 8.1 Create CSI Namespace

```bash
kubectl create namespace csi-wekafs
```

### 8.2 Create API Secret

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

### 8.3 Install CSI Plugin

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
nodes** — the CSI controller performs local WEKA filesystem mounts for
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
```

Expected output:

```text
NAME                                     READY   STATUS    RESTARTS   AGE
csi-wekafs-controller-59965597b9-rvcmg   6/6     Running   0          2m40s
csi-wekafs-controller-59965597b9-zmk6b   6/6     Running   0          2m40s
csi-wekafs-node-654t7                    3/3     Running   0          2m40s
csi-wekafs-node-nfnh4                    3/3     Running   0          2m40s
```

You should see:

- Two controller pods (for HA)
- One node pod per labeled EKS node

### 8.4 Create StorageClass

Review `manifests/core/storageclass-weka.yaml` and adjust as needed:

| Parameter             | Options                                        | Description                                                                                                |
|-----------------------|------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| `volumeBindingMode`   | `WaitForFirstConsumer` (default), `Immediate`  | `WaitForFirstConsumer` delays provisioning until a pod uses the PVC - better for topology-aware scheduling |
| `reclaimPolicy`       | `Delete` (default), `Retain`                   | `Delete` removes the volume when PVC is deleted; `Retain` keeps it                                         |
| `filesystemName`      | `default`                                      | WEKA filesystem to use for volumes                                                                         |
| `capacityEnforcement` | `HARD`, `SOFT`                                 | `HARD` enforces quota limits strictly                                                                      |

Create the storage class and then check that it created:

```bash
kubectl apply -f manifests/core/storageclass-weka.yaml
kubectl get storageclass | grep weka
```

---

## Test Dynamic Provisioning

Deploy a test PVC and pod to verify the WEKA CSI integration.

### 9.1 Review Test Manifests

The test manifests in `manifests/test/` include:

**pvc.yaml** - PersistentVolumeClaim:

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

PVC configuration options:

| Field         | Options                                          | Description                                       |
|---------------|--------------------------------------------------|---------------------------------------------------|
| `accessModes` | `ReadWriteMany`, `ReadWriteOnce`, `ReadOnlyMany` | WEKA supports all modes; RWX allows multiple pods |
| `volumeMode`  | `Filesystem` (default), `Block`                  | `Filesystem` for mounted directories              |
| `storage`     | e.g. `10Gi`, `100Gi`                             | Requested volume size                             |

**weka-writer.yaml** - Writes a file to the PVC:

- Mounts `pvc-wekafs-dir` at `/data`
- Writes `hello.txt` then sleeps

**weka-reader.yaml** - Reads the file written by `weka-writer`:

- Mounts the same PVC at `/data`
- Reads `hello.txt` then sleeps
- Demonstrates ReadWriteMany across pods

Both pods use `nodeSelector: weka.io/supports-clients=true` and
tolerate `weka.io/client=true:NoSchedule` so they schedule on WEKA
client nodes.

### 9.2 Deploy Test Resources

```bash
kubectl create namespace weka-test
kubectl apply -f manifests/test/
```

### 9.3 Verify PVC Binding

```bash
kubectl get pvc -n weka-test
```

Expected output - PVC should be `Bound`:

```text
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                  AGE
pvc-wekafs-dir   Bound    pvc-835773b4-c060-455d-94a4-ec2ee85987b9   10Gi       RWX            storageclass-wekafs-dir-api   15s
```

If the PVC stays in `Pending` state, check events:

```bash
kubectl describe pvc pvc-wekafs-dir -n weka-test
```

**Common causes of Pending PVC:**

- API secret values not base64 encoded
- Missing required fields in API secret (`scheme`, `organization`, `endpoints`)
- Incorrect WEKA backend credentials (username/password)
- CSI controller pods not running (check `kubectl get pods -n csi-wekafs`)

### 9.4 Verify Pod Running

```bash
kubectl get pods -n weka-test
```

Expected output:

```text
NAME              READY   STATUS    RESTARTS   AGE
weka-writer       1/1     Running   0          60s
weka-reader       1/1     Running   0          60s
```

### 9.5 Verify Data Written

Check that the writer pod successfully wrote to the WEKA volume:

```bash
kubectl logs weka-writer -n weka-test
```

Expected output shows directory listing:

```text
total 4
drwxrwxrwx    2 root     root          4096 Jan 12 12:00 .
drwxr-xr-x    1 root     root          4096 Jan 12 12:00 ..
-rw-r--r--    1 root     root            18 Jan 12 12:00 hello.txt
```

### 9.6 Verify Shared Access (ReadWriteMany)

The reader pod mounts the same PVC and reads the file written by the
writer — confirming ReadWriteMany works across pods:

```bash
kubectl logs weka-reader -n weka-test
```

Expected output:

```text
Reading data written by another pod:
Hello from WEKA!
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

---

## Troubleshooting

### Quick Checks

```bash
# Pod status
kubectl get pods -n weka-operator-system

# Pod events
kubectl describe pod -n weka-operator-system -l mode=client

# Hugepages
kubectl get nodes -l weka.io/supports-clients=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi

# WEKA client logs
kubectl logs -n weka-operator-system -l mode=client
```
