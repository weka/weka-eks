# WEKA Dedicated on EKS

Separate WEKA storage cluster with EKS compute cluster.

## Architecture

<!-- TODO: Add architecture diagram -->
<!-- ![Architecture](../img/weka-dedicated/architecture.png) -->

- **WEKA Backend**: 6+ i3en instances with NVMe storage
- **EKS Cluster**: System nodes + WEKA client nodes
- **Networking**: WEKA clients connect to backend via dedicated NICs (DPDK) or primary interface (UDP)

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform 1.5+
- kubectl, Helm 3.x
- WEKA download token from [get.weka.io](https://get.weka.io)
- Quay.io credentials for WEKA container images

## Directory Structure

```
weka-dedicated/
├── terraform/
│   ├── weka-backend/    # WEKA storage cluster
│   └── eks/             # EKS cluster
├── manifests/           # Kubernetes manifests
│   ├── core/            # Required manifests (weka-client, CSI, etc.)
│   └── test/            # Test PVC and pod
└── deploy.sh            # Automated deployment script
```

---

## Manual Deployment

### Step 1: Deploy WEKA Backend

```bash
cd terraform/weka-backend
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform apply
```

See [terraform/weka-backend/README.md](terraform/weka-backend/README.md) for configuration details.

Save these outputs for EKS configuration:
```bash
# Security group for EKS nodes (use in additional_node_security_group_ids)
terraform output -json weka_deployment_output | jq -r '.sg_ids[]'

# Get backend IPs for WekaClient configuration
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*<cluster_name>*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '\t' '\n'
```

### Step 2: Deploy EKS Cluster

```bash
cd ../eks
cp terraform.tfvars.example terraform.tfvars
```

Edit terraform.tfvars:
- Set `additional_node_security_group_ids` to the WEKA backend security group
- Configure WEKA client node group with required settings:

```hcl
node_groups = {
  clients = {
    instance_types   = ["c6i.12xlarge"]
    imds_hop_limit_2 = true  # Required for ensure-nics
    labels = {
      "weka.io/supports-clients" = "true"
    }
  }
}
```

```bash
terraform init
terraform apply
```

See [terraform/eks/README.md](terraform/eks/README.md) for configuration details.

### Step 3: Configure kubectl

```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
kubectl get nodes
```

Verify WEKA client nodes are labeled:
```bash
kubectl get nodes -l weka.io/supports-clients=true
```

### Step 4: Deploy WEKA Operator

#### 4.1 Create Namespace

```bash
kubectl create namespace weka-operator-system
```

#### 4.2 Create Quay.io Pull Secret

```bash
kubectl create secret docker-registry weka-quay-io-secret \
  --namespace weka-operator-system \
  --docker-server=quay.io \
  --docker-username="YOUR_QUAY_USERNAME" \
  --docker-password="YOUR_QUAY_PASSWORD"
```

#### 4.3 Install WEKA Operator

```bash
helm upgrade --install weka-operator \
  oci://quay.io/weka.io/helm/weka-operator \
  --namespace weka-operator-system \
  --version v1.9.0 \
  --set imagePullSecret=weka-quay-io-secret \
  --wait
```

#### 4.4 Verify

```bash
kubectl get pods -n weka-operator-system
# Should show: weka-operator-xxxxx Running
```

### Step 5: Configure Hugepages

WEKA clients require hugepages. The formula is **1.5 GB per core** (768 × 2MB pages per core).

```bash
kubectl apply -f manifests/core/hugepages-daemonset.yaml
```

Wait 30-60 seconds for kubelet restart, then verify:
```bash
kubectl get nodes -l weka.io/supports-clients=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi
```

Expected output:

```text
NAME                                        HUGEPAGES
ip-10-0-1-59.eu-west-1.compute.internal     3Gi
ip-10-0-10-160.eu-west-1.compute.internal   3Gi
```

### Step 6: Run ensure-nics

Creates dedicated network interfaces for WEKA's DPDK networking.

Edit `manifests/core/ensure-nics.yaml`:
- Set `dataNICsNumber` to match your desired core count (default: 2)

```bash
kubectl apply -f manifests/core/ensure-nics.yaml
```

Wait for completion:
```bash
kubectl get wekapolicies -n weka-operator-system -w
# Wait for STATUS: Done
```

### Step 7: Deploy WekaClient

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
  image: quay.io/weka.io/weka-in-container:4.4.10.183
  imagePullSecret: weka-quay-io-secret
  driversDistService: "https://drivers.weka.io"
  portRange:
    basePort: 46000
  nodeSelector:
    weka.io/supports-clients: "true"

  # Backend IPs from Step 1 (port 14000 for management)
  joinIpPorts:
    - "10.0.67.159:14000"
    - "10.0.67.15:14000"
    - "10.0.66.95:14000"
    - "10.0.65.82:14000"
    - "10.0.64.194:14000"
    - "10.0.67.69:14000"

  # Must match dataNICsNumber from ensure-nics (Step 6)
  coresNum: 2

  # Formula: coresNum × 1536 (1.5GB per core)
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

#### 7.1 Verify Clients in WEKA Web UI

Access the WEKA web UI and verify clients appear:

![WEKA Clients](../img/weka-dedicated/weka-clients.png)

The clients should appear in the WEKA GUI under the Clients section with status "UP".

### Step 8: Deploy WEKA CSI Plugin

#### 8.1 Create CSI Namespace

```bash
kubectl create namespace csi-wekafs
```

#### 8.2 Create API Secret

Copy and edit the example manifest:

```bash
cp manifests/core/csi-wekafs-api-secret.yaml.example manifests/core/csi-wekafs-api-secret.yaml
```

Edit `manifests/core/csi-wekafs-api-secret.yaml`. All `data` values must be **base64 encoded**. For example:

```yaml
data:
  username: admin
  password: admin-password
  scheme: https
  endpoints: 10.0.67.159:14000, 10.0.67.15:14000,10.0.67.69:14000
  organization: Root
```

would look like this in a base64 encoding:

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
  endpoints: MTAuMC42Ny4xNTk6MTQwMDAsIDEwLjAuNjcuMTU6MTQwMDAsMTAuMC42Ny42OToxNDAwMA==
  organization: Um9vdA==
```

To encode a value:

```bash
echo -n 'your-value' | base64
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

#### 8.3 Install CSI Plugin

Add the WEKA CSI helm repo:

```bash
helm repo add csi-wekafs https://weka.github.io/csi-wekafs
helm repo update
```

Review `manifests/core/values-csi-wekafs.yaml`:

```yaml
node:
  nodeSelector:
    weka.io/supports-clients: "true"

pluginConfig:
  allowInsecureHttps: true
```

Key settings:

- **nodeSelector**: Restricts CSI node pods to WEKA client nodes only (avoids deploying on system nodes)
- **allowInsecureHttps**: Required when the WEKA backend uses self-signed SSL certificates

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

You should see two controller pods (for HA) and one node pod per labeled EKS node.

#### 8.4 Create StorageClass

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

This section walks through deploying a test PVC and pod to verify the WEKA CSI integration works.

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

**weka-mount-test.yaml** - Test pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: weka-pvc-test
  namespace: weka-test
spec:
  nodeSelector:
    weka.io/supports-clients: "true"  # Schedule on WEKA client nodes
  containers:
  - name: test-container
    image: busybox
    volumeMounts:
    - name: weka-volume
      mountPath: "/data"
    command: ["sh", "-c", "echo 'Hello from WEKA!' > /data/hello.txt && ls -la /data && sleep 3600"]
  volumes:
  - name: weka-volume
    persistentVolumeClaim:
      claimName: pvc-wekafs-dir
```

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
NAME            READY   STATUS    RESTARTS   AGE
weka-pvc-test   1/1     Running   0          60s
```

### 9.5 Verify Data Written

Check that the pod successfully wrote to the WEKA volume:

```bash
kubectl logs weka-pvc-test -n weka-test
```

Expected output shows directory listing:

```text
total 4
drwxrwxrwx    2 root     root          4096 Jan 12 12:00 .
drwxr-xr-x    1 root     root          4096 Jan 12 12:00 ..
-rw-r--r--    1 root     root            18 Jan 12 12:00 hello.txt
```

Verify file contents:

```bash
kubectl exec weka-pvc-test -n weka-test -- cat /data/hello.txt
```

### 9.6 Cleanup Test Resources

```bash
kubectl delete namespace weka-test
```

---

## Automated Deployment

After configuring the manifests, use the deployment script:

```bash
# Deploy with arguments
./deploy.sh <cluster-name> <quay-username> <quay-password>

# Or with environment variables
export CLUSTER_NAME=my-eks-cluster
export QUAY_USERNAME=your-username
export QUAY_PASSWORD=your-password
./deploy.sh

# Cleanup - remove all WEKA components
./deploy.sh --cleanup <cluster-name>
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CLUSTER_NAME` | EKS cluster name | Required |
| `QUAY_USERNAME` | Quay.io username | Required |
| `QUAY_PASSWORD` | Quay.io password | Required |
| `WEKA_OPERATOR_VERSION` | Operator Helm chart version | `v1.9.0` |

### What the Script Does

1. Configures kubectl for EKS cluster
2. Creates namespace and Quay.io pull secret
3. Installs WEKA Operator via Helm
4. Applies hugepages DaemonSet
5. Applies ensure-nics WekaPolicy
6. Applies WekaClient manifest
7. Installs CSI plugin via Helm and applies StorageClass
8. Runs smoke test (creates PVC and test pod)

---

## Cleanup

### Remove WEKA Components

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
# EKS cluster
cd terraform/eks
terraform destroy

# WEKA backend
cd ../weka-backend
terraform destroy
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

### Common Issues

| Issue | Solution |
|-------|----------|
| `ImagePullBackOff` | Check Quay.io credentials |
| `Insufficient hugepages` | Verify hugepages DaemonSet ran |
| `ensure-nics stuck` | Check IMDS hop limit is 2 |
| `Connection refused` | Check security groups |
