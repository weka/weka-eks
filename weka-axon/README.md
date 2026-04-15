# WEKA Axon on Amazon EKS

Deploy a converged WEKA cluster on Amazon EKS, where backend
(drive + compute), client, and application workloads all run on
the same nodes.

## Architecture

Two node groups:

1. **System nodes** -- Kubernetes components (CoreDNS, kube-proxy,
   VPC CNI), WEKA operator controller, CSI controller.
2. **Axon nodes** -- WEKA drive + compute + client containers and
   application pods. Large instances with local NVMe (e.g.
   i3en.12xlarge, p5.48xlarge). Labeled with
   `weka.io/supports-backends` and `weka.io/supports-clients`,
   tainted with `weka.io/axon=true:NoSchedule` to restrict
   scheduling to WEKA processes and application pods only.

See [terraform/README.md](terraform/README.md) for node group
configuration details.

## Prerequisites

* AWS account with permissions to create EKS, EC2, IAM resources
* Existing VPC with subnets (private subnets recommended)
* Terraform >= 1.6
* kubectl
* Helm 3.x
* Quay.io credentials for WEKA images (available at
  [get.weka.io](https://get.weka.io))

## Repository Layout

The code is split into two main parts:

* Terraform to deploy the EKS cluster
  * The root Terraform directory defines the environment and instantiates modules
  * The EKS Axon module implements the actual EKS infrastructure
* A collection of manifests to define the Kubernetes resources
  * Core resources that define the resources managed by the WEKA operator
  * A sample set of manifests to show how to use the WEKA storage cluster in EKS

```text
terraform/
  modules/
    eks-axon/
       main.tf
       outputs.tf
       variables.tf
  main.tf
  outputs.tf
  terraform.tfvars
  variables.tf
manifests/
  core/
    ensure-nics.yaml
    sign-drives.yaml
    storageclass-weka.yaml
    values-weka-operator.yaml
    weka-cluster.yaml
    weka-client.yaml
  test/
    pvc.yaml
    weka-app.yaml
    weka-app-reader.yaml
deploy.sh
```

## 1. Deploy EKS Infrastructure (Terraform)

All commands assume you are in the `weka-axon/` directory.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

### 1.1 Configure Terraform

Edit `terraform.tfvars`. Key variables:

* `region`
* `cluster_name`
* `subnet_ids`
* `admin_role_arn` (IAM role for cluster admin access)
* `enable_ssm_access` (enabled by default for node debugging)

Hugepages must be configured per node group -- see
[section 3.2](#32-hugepages) for sizing details.

### 1.2 Node Groups

Node groups are defined as a map. The example below is a base
configuration for testing on `i3en.12xlarge` instances. Adjust
instance type, node count, and resource settings for your
environment. Example:

```hcl
node_groups = {
  system = {
    instance_types = ["m6i.large"]
    desired_size   = 2
    min_size       = 2
    max_size       = 4

    labels = {
      "node.kubernetes.io/role" = "system"
    }
    ami_type = "AL2023_x86_64_STANDARD"
  }

  storage = {
    instance_types = ["i3en.12xlarge"]
    desired_size   = 6
    min_size       = 6
    max_size       = 12

    disk_size = 200
    imds_hop_limit_2 = true
    ami_type = "AL2023_x86_64_STANDARD"
    enable_cpu_manager_static = true
    hugepages_count = 6144

    labels = {
      "weka.io/supports-backends" = "true"
      "weka.io/supports-clients"  = "true"
    }

    taints = [
      {
        key    = "weka.io/axon"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
  }
}
```

The storage group sets labels, taints, CPU manager, hugepages,
and IMDS hop limit for WEKA. System nodes need none of these.

### 1.3 Terraform Deployment

Create the EKS cluster (takes about 10-15 minutes):

```bash
terraform init && terraform apply

# Configure kubectl
$(terraform output -raw configure_kubectl)
cd ..
```

Verify nodes:

```bash
kubectl get nodes -o wide
 
NAME                                        STATUS   ROLES    AGE     VERSION               INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
ip-10-0-0-183.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f   10.0.0.183    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-10-107.us-west-2.compute.internal   Ready    <none>   3h14m   v1.33.8-eks-f69f56f   10.0.10.107   <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-10-68.us-west-2.compute.internal    Ready    <none>   3h13m   v1.33.8-eks-f69f56f   10.0.10.68    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-11-31.us-west-2.compute.internal    Ready    <none>   3h13m   v1.33.8-eks-f69f56f   10.0.11.31    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-11-54.us-west-2.compute.internal    Ready    <none>   3h13m   v1.33.8-eks-f69f56f   10.0.11.54    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-7-157.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f   10.0.7.157    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-8-68.us-west-2.compute.internal     Ready    <none>   3h13m   v1.33.8-eks-f69f56f   10.0.8.68     <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-8-81.us-west-2.compute.internal     Ready    <none>   3h14m   v1.33.8-eks-f69f56f   10.0.8.81     <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
```

```bash
kubectl get nodes -L weka.io/supports-backends,weka.io/supports-clients

NAME                                        STATUS   ROLES    AGE     VERSION               SUPPORTS-BACKENDS   SUPPORTS-CLIENTS
ip-10-0-0-183.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f
ip-10-0-10-107.us-west-2.compute.internal   Ready    <none>   3h14m   v1.33.8-eks-f69f56f   true                true
ip-10-0-10-68.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f   true                true
ip-10-0-11-31.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f   true                true
ip-10-0-11-54.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f   true                true
ip-10-0-7-157.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.8-eks-f69f56f
ip-10-0-8-68.us-west-2.compute.internal     Ready    <none>   3h14m   v1.33.8-eks-f69f56f   true                true
ip-10-0-8-81.us-west-2.compute.internal     Ready    <none>   3h14m   v1.33.8-eks-f69f56f   true                true
```

## 2. Install WEKA Operator (with embedded CSI)

The [WEKA Operator](https://docs.weka.io/kubernetes/weka-operator-deployments)
manages WEKA storage components via Kubernetes Custom Resources
(WekaCluster, WekaClient). We'll install it with the
[CSI plugin](https://docs.weka.io/appendices/weka-csi-plugin)
enabled, which simplifies secret and StorageClass setup.

> **Note:** The CSI node and controller pods may restart several times
> during initial deployment. This is expected — they start with the
> operator but require WEKA client containers to be running before
> they can serve mounts. They will stabilize once clients are active.

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

Install the operator and CSI plugin:

```bash
helm upgrade --install weka-operator \
  oci://quay.io/weka.io/helm/weka-operator \
  --namespace weka-operator-system \
  --version v1.11.0 \
  --set imagePullSecret=weka-quay-io-secret \
  --set csi.installationEnabled=true \
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
weka-operator-node-agent-58pfc                      1/1     Running   0          82s
weka-operator-node-agent-d6r7x                      1/1     Running   0          82s
weka-operator-node-agent-dbql8                      1/1     Running   0          82s
weka-operator-node-agent-fmftp                      1/1     Running   0          82s
weka-operator-node-agent-gzzdh                      1/1     Running   0          82s
weka-operator-node-agent-lmg6k                      1/1     Running   0          82s
```

## 3. Cluster Resources

Plan resource allocation before deploying. The WEKA storage
cluster has three process types:

* Compute processes: Handles filesystems, cluster-level
  functions, and IO from clients
* Drive processes: Manages SSD drives and IO operations to
  the drives
* Frontend (client) processes: Manages POSIX client access and
  coordinates IO operations with compute and drive processes

Each process needs a dedicated CPU core and ideally a dedicated
ENI. Planning guidelines:

* **1 drive process** per NVMe drive, up to 6 SSDs
  * Above 6 SSDs, use 1 drive process per 2 SSDs
* A ratio of **2 compute processes** per drive process
* **1 frontend process** per node
* Memory requirements:
  * 2.8 GB fixed
  * 2.2 GB per frontend process
  * 3.9 GB per compute process
  * 2 GB per drive process

In AWS, the ENI limit per instance constrains how many processes
you can run. Account for 1 ENI for management and 1 for EKS VPC
CNI. Production Axon deployments typically use larger GPU instances
(p5, p6) which have more ENIs available.

### 3.1 Example: i3en.12xlarge

| Resource | Value |
| -------- | ----- |
| vCPU | 48 (24 physical cores, 2 threads each) |
| Memory | 384 GiB |
| NVMe | 4 x 7500 GB |
| Max ENIs | 8 |

Per-node allocation:

| Component | Cores | ENIs |
| --------- | ----- | ---- |
| Drive processes | 2 | 2 |
| Compute processes | 2 | 2 |
| Frontend/client | 1 | 1 |
| Management + EKS | -- | 2 |
| Application pod | 1 | 1 |
| **Total** | **6** | **8** |

Memory: ~16.8 GB for WEKA processes.

### 3.2 Hugepages

WEKA uses 2 MiB hugepages for all container processes. The node
must have enough total hugepages to cover every container that
will run on it. Each container's request includes a base
allocation plus a DPDK memory component and an offset.

**Per-container formulas** (from the operator source):

| Container | Hugepages (MiB) | Offset (MiB) |
| --------- | --------------- | ------------ |
| Drive | `1400 * driveCores + 200 * numDrives + 64 * driveCores` | `200 * numDrives + 64 * driveCores` |
| Compute | `computeHugepages + 64 * computeCores` | `200 + 64 * computeCores` |
| Client | `clientCores * (1500 + 64)` | `200 + 64 * clientCores` |

Each pod requests `hugepages + offset` from the node pool.

**Example: i3en.12xlarge (2 compute cores, 2 drive cores,
1 client core, numDrives=1)**

| Container | Hugepages | Offset | Pod request |
| --------- | --------- | ------ | ----------- |
| Drive | 3128 | 328 | 3456 MiB |
| Compute (6144 explicit) | 6272 | 328 | 6600 MiB |
| Client | 1564 | 264 | 1828 MiB |
| **Per-node total** | | | **11884 MiB** |

Convert to pages: `11884 / 2 = 5942 pages`. Add headroom:
**6144 pages** (12288 MiB).

Set this in `terraform.tfvars`:

```hcl
hugepages_count = 6144
```

Hugepages are configured at node boot via the launch template
user data.

Verify allocation after nodes are running:

```bash
kubectl get nodes -l weka.io/supports-backends=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi
```

## 4. Configure NICs

WEKA uses [DPDK](https://docs.weka.io/weka-system-overview/networking-in-wekaio)
for high-performance networking, which requires dedicated ENIs
per WEKA process. The `ensure-nics` WekaPolicy creates and attaches
additional ENIs to each node.

`dataNICsNumber` is the total secondary NICs on the instance
(WEKA data NICs + 1 for the EKS VPC CNI). For the `i3en.12xlarge`
with 8 ENI max, we use all 7 secondary slots (6 for WEKA + 1 EKS).

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
        weka.io/supports-backends: "true"
      dataNICsNumber: 7
```

Apply the policy:

```bash
kubectl apply -f manifests/core/ensure-nics.yaml
```

Check the status after a few minutes:

```bash
kubectl get wekapolicy ensure-nics-policy -n weka-operator-system -o json \
| jq -r '
  "lastRunTime=\(.status.lastRunTime) status=\(.status.status)\n" +
  (.status.result | fromjson | .results
    | to_entries[]
    | "\(.key)\tensured=\(.value.ensured)\tnics=\((.value.nics|length))\terr=\(.value.err)")'

lastRunTime=2026-02-05T14:31:12Z status=Done
ip-10-0-2-195.us-west-2.compute.internal ensured=true nics=7 err=null
ip-10-0-3-221.us-west-2.compute.internal ensured=true nics=7 err=null
ip-10-0-4-159.us-west-2.compute.internal ensured=true nics=7 err=null
ip-10-0-7-149.us-west-2.compute.internal ensured=true nics=7 err=null
ip-10-0-8-123.us-west-2.compute.internal ensured=true nics=7 err=null
ip-10-0-8-94.us-west-2.compute.internal ensured=true nics=7 err=null
```

This runs every 5 minutes and checks for nodes that need
additional NICs.

## 5. Prepare Drives

Local NVMe drives must be discovered and signed before WEKA can
use them. The `sign-drives` WekaPolicy handles this automatically.

For manual drive selection (e.g. only a subset of NVMe drives),
see the [WEKA documentation](https://docs.weka.io/kubernetes/weka-operator-deployments#id-5.-discover-drives-for-weka-cluster-provisioning).

Review `manifests/core/sign-drives.yaml`:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaPolicy
metadata:
  name: sign-drives-policy
  namespace: weka-operator-system
spec:
  type: sign-drives
  payload:
    signDrivesPayload:
      type: "aws-all"
      nodeSelector:
        weka.io/supports-backends: "true"
```

The main options to note here are

* `type`: set to `aws-all` for AWS deployments
* `nodeSelector`: target only WEKA storage nodes

Apply the policy:

```bash
kubectl apply -f manifests/core/sign-drives.yaml
```

We can check the status of the policy:

```bash
kubectl get wekapolicy sign-drives-policy -n weka-operator-system

NAME                 TYPE          STATUS   PROGRESS
sign-drives-policy   sign-drives   Done
```

Wait until STATUS shows `Done`.

## 6. Deploy WEKA Cluster

The `WekaCluster` CR defines the WEKA backend (drive + compute
containers). Review `manifests/core/weka-cluster.yaml` and adjust
based on resource planning from section 3:

* `spec.dynamicTemplate`
  * `computeContainers`: total compute containers in the cluster (max 1 per node)
  * `computeCores`: cores per compute container
  * `computeHugepages`: hugepages per compute container (MiB).
    Required with operator v1.11.0. Formula: `computeCores * 3072`
  * `driveContainers`: total drive containers (max 1 per node)
  * `driveCores`: cores per drive container
  * `numDrives`: drives per drive container. Required with operator
    v1.11.0 (set to `1` for full-drives mode)
* `spec.nodeSelector`: targets `weka.io/supports-backends: true`
* `spec.rawTolerations`: `weka.io/axon=true:NoSchedule` so backend
  pods can schedule on tainted nodes
* `spec.image` and `spec.imagePullSecret`: WEKA version and quay.io
  pull secret
* `spec.network.udpMode: false`: use DPDK with dedicated ENIs

Example for `i3en.12xlarge`:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaCluster
metadata:
  name: weka-axon-eks-cluster
  namespace: weka-operator-system
spec:
  template: dynamic
  dynamicTemplate:
    computeContainers: 6
    computeCores: 2
    computeHugepages: 6144
    driveContainers: 6
    driveCores: 2
    numDrives: 1
  image: quay.io/weka.io/weka-in-container:4.4.21.2
  imagePullSecret: "weka-quay-io-secret"
  nodeSelector:
    weka.io/supports-backends: "true"
  rawTolerations:
    - key: "weka.io/axon"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
  driversDistService: https://drivers.weka.io
  gracefulDestroyDuration: "0"
  ports:
    basePort: 15000
  network:
    udpMode: false
```

Apply the WekaCluster manifest:

```bash
kubectl apply -f manifests/core/weka-cluster.yaml
```

Verify the WEKA cluster is created:

```bash
kubectl get wekacluster -n weka-operator-system

NAME                    STATUS   CLUSTER ID                             CCT(A/C/D)   DCT(A/C/D)   DRVS(A/C/D)
weka-axon-eks-cluster   Ready    b78e7df9-76d1-423c-bd7c-5a0a988cd568   6/6/6        6/6/6        6/6/6
```

And you can check that the compute and drive pods are running:

```bash
kubectl get pods -n weka-operator-system | grep -E 'weka-axon-eks-cluster-(compute|drive)'   

weka-axon-eks-cluster-compute-044c57f8-c6b5-4349-aefe-2c4f3e7b0e22   1/1     Running   0          3m48s
weka-axon-eks-cluster-compute-2c98e65c-25c4-4790-b0c4-930c1e440148   1/1     Running   0          3m47s
weka-axon-eks-cluster-compute-2d01aef5-e0a2-47e1-993b-7186ad15b389   1/1     Running   0          3m47s
weka-axon-eks-cluster-compute-2fb097e6-e1f0-4f97-9204-33d9756e896a   1/1     Running   0          3m48s
weka-axon-eks-cluster-compute-3817114f-0d60-4af2-8c35-998c2a3330a4   1/1     Running   0          3m47s
weka-axon-eks-cluster-compute-898fae0b-2ddb-4958-b378-2f75906d5c8a   1/1     Running   0          3m48s
weka-axon-eks-cluster-drive-04739f74-8f4a-4a09-94ee-89e52fec4052     1/1     Running   0          3m48s
weka-axon-eks-cluster-drive-11941029-0c8d-43be-9c5c-e2adfa0c481f     1/1     Running   0          3m48s
weka-axon-eks-cluster-drive-977c355a-65a2-4d33-a0f6-0cbda724f394     1/1     Running   0          3m48s
weka-axon-eks-cluster-drive-9e8a6ecc-54a2-4e6b-93cf-7baae64731e2     1/1     Running   0          3m48s
weka-axon-eks-cluster-drive-bef1d7eb-1af4-4057-8e25-d94363790f99     1/1     Running   0          3m48s
weka-axon-eks-cluster-drive-da653d8e-c4d5-4a6b-9628-39d18aed4102     1/1     Running   0          3m48s
```

## 7. Deploy WEKA Client

The `WekaClient` CR creates frontend processes that provide POSIX
access to the cluster. In an Axon deployment, clients run on the
same nodes as the backend. Review `manifests/core/weka-client.yaml`:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaClient
metadata:
  name: weka-axon-eks-client
  namespace: weka-operator-system
spec:
  autoRemoveTimeout: "24h0m0s"
  coresNum: 1
  cpuPolicy: dedicated
  cpuRequest: "500m"
  driversDistService: https://drivers.weka.io
  image: quay.io/weka.io/weka-in-container:4.4.21.2
  imagePullSecret: "weka-quay-io-secret"
  network: {}
  nodeSelector:
    weka.io/supports-clients: "true"
  rawTolerations:
    - key: "weka.io/axon"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
  portRange:
    basePort: 46000
    portRange: 0
  targetCluster:
    name: weka-axon-eks-cluster
    namespace: weka-operator-system
  upgradePolicy:
    type: all-at-once
  wekaHomeConfig: {}
```

Key fields:

* `spec.coresNum`: cores for the client process
* `spec.targetCluster`: points to the local WekaCluster
* `spec.rawTolerations`: allows scheduling on tainted axon nodes

Apply:

```bash
kubectl apply -f manifests/core/weka-client.yaml
```

Verify the client has deployed:

```bash
kubectl get wekaclient -n weka-operator-system

NAME                   STATUS    TARGET CLUSTER          CORES   CONTAINERS(A/C/D)
weka-axon-eks-client   Running   weka-axon-eks-cluster   1       6/6/6
```

## 8. Verify WEKA Processes

### Client verification

Verify WEKA is running by executing `weka local ps` on a
client pod:

```bash
kubectl get pods -n weka-operator-system -o wide | grep -i client

weka-axon-eks-client-ip-10-0-2-195.us-west-2.compute.internal        1/1     Running   0               3m3s    10.0.2.195    ip-10-0-2-195.us-west-2.compute.internal   <none>           <none>
weka-axon-eks-client-ip-10-0-3-221.us-west-2.compute.internal        1/1     Running   0               3m3s    10.0.3.221    ip-10-0-3-221.us-west-2.compute.internal   <none>           <none>
weka-axon-eks-client-ip-10-0-4-159.us-west-2.compute.internal        1/1     Running   0               3m3s    10.0.4.159    ip-10-0-4-159.us-west-2.compute.internal   <none>           <none>
weka-axon-eks-client-ip-10-0-7-149.us-west-2.compute.internal        1/1     Running   0               3m3s    10.0.7.149    ip-10-0-7-149.us-west-2.compute.internal   <none>           <none>
weka-axon-eks-client-ip-10-0-8-123.us-west-2.compute.internal        1/1     Running   0               3m3s    10.0.8.123    ip-10-0-8-123.us-west-2.compute.internal   <none>           <none>
weka-axon-eks-client-ip-10-0-8-94.us-west-2.compute.internal         1/1     Running   0               3m3s    10.0.8.94     ip-10-0-8-94.us-west-2.compute.internal    <none>           <none>
```

And then select one on which to run `weka local ps`:

```bash
kubectl exec -n weka-operator-system weka-axon-eks-client-ip-10-0-2-195.us-west-2.compute.internal -c weka-container -- \
  bash -lc 'weka local ps'

CONTAINER           STATE    DISABLED  UPTIME    MONITORING  PERSISTENT   PORT  PID  STATUS  VERSION     LAST FAILURE
3dec9945aea2client  Running  True      0:04:32h  True        True        46001  822  Ready   4.4.21.2
```

### 8.1 Access WEKA Web UI

The WEKA UI is exposed internally via a **management proxy service**.

Find the service:

```bash
kubectl get svc -n weka-operator-system | grep proxy

weka-axon-eks-cluster-management-proxy             ClusterIP   172.20.218.96   <none>        15305/TCP
```

You can now set up a port-forward:

```bash
kubectl port-forward -n weka-operator-system svc/weka-axon-eks-cluster-management-proxy 15305:15305
```

Access locally in a web browser at:

```bash
http://localhost:15305
```

Retrieve the admin credentials (created by the operator):

```bash
kubectl get secret -n weka-operator-system weka-cluster-weka-axon-eks-cluster \
  -o jsonpath='{.data.username}' | base64 -d; echo

kubectl get secret -n weka-operator-system weka-cluster-weka-axon-eks-cluster \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Once logged in you should see the cluster:

![WEKA Axon UI](../img/weka-axon/weka-axon-ui.png)

## 9. CSI and StorageClass

Because we installed the operator with `csi.installationEnabled=true`,
the CSI plugin, API secret, and default StorageClasses were created
automatically. You can verify:

```bash
kubectl get secrets -n weka-operator-system | grep csi
```

```text
weka-csi-weka-axon-eks-cluster   Opaque   5   ...
```

```bash
kubectl get storageclass | grep weka
```

```text
weka-weka-axon-eks-cluster-weka-operator-system-default               ...   Delete   Immediate   true   ...
weka-weka-axon-eks-cluster-weka-operator-system-default-forcedirect   ...   Delete   Immediate   true   ...
```

The API secret values are base64-encoded. To decode and inspect:

```bash
kubectl get secret -n weka-operator-system weka-csi-weka-axon-eks-cluster \
  -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

If you need to create a custom CSI secret (e.g. for a different
cluster), all `data` values must be base64-encoded. Incorrect encoding
is a common source of CSI errors.

We'll create an additional StorageClass with `WaitForFirstConsumer`
binding mode. Review `manifests/core/storageclass-weka.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: storageclass-wekafs-dir-api
provisioner: weka-axon-eks-cluster.weka-operator-system.weka.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  volumeType: dir/v1
  filesystemName: default
  capacityEnforcement: HARD
  csi.storage.k8s.io/provisioner-secret-name: &secretName weka-csi-weka-axon-eks-cluster
  csi.storage.k8s.io/provisioner-secret-namespace: &secretNamespace weka-operator-system
  csi.storage.k8s.io/controller-publish-secret-name: *secretName
  csi.storage.k8s.io/controller-publish-secret-namespace: *secretNamespace
  csi.storage.k8s.io/controller-expand-secret-name: *secretName
  csi.storage.k8s.io/controller-expand-secret-namespace: *secretNamespace
  csi.storage.k8s.io/node-stage-secret-name: *secretName
  csi.storage.k8s.io/node-stage-secret-namespace: *secretNamespace
  csi.storage.k8s.io/node-publish-secret-name: *secretName
  csi.storage.k8s.io/node-publish-secret-namespace: *secretNamespace
```

Key settings:

* `dir/v1` volume type on the `default` filesystem
* `WaitForFirstConsumer` delays provisioning until a pod
  uses the PVC
* `reclaimPolicy: Delete` removes the volume when the PVC
  is deleted

See the [WEKA CSI documentation](https://docs.weka.io/appendices/weka-csi-plugin/storage-class-configurations)
for other parameters. Make sure `provisioner-secret-name` and
`provisioner-secret-namespace` match your CSI secret.

Create the StorageClass:

```bash
kubectl apply -f manifests/core/storageclass-weka.yaml
```

You should now see it in the list of other StorageClasses:

```bash
kubectl get storageclass

NAME                                                                  PROVISIONER                                          RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
gp2                                                                   kubernetes.io/aws-ebs                                Delete          WaitForFirstConsumer   false                  15h
storageclass-wekafs-dir-api                                           weka-axon-eks-cluster.weka-operator-system.weka.io   Delete          WaitForFirstConsumer   true                   105s
weka-weka-axon-eks-cluster-weka-operator-system-default               weka-axon-eks-cluster.weka-operator-system.weka.io   Delete          Immediate              true                   14h
weka-weka-axon-eks-cluster-weka-operator-system-default-forcedirect   weka-axon-eks-cluster.weka-operator-system.weka.io   Delete          Immediate              true                   14h
```

Now create a PVC and test pod using this StorageClass.

### 9.3 Create Test PVC

First create a namespace for our test application:

```bash
kubectl create namespace weka-axon-test 
```

A sample PVC is provided:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-wekafs-dir
  namespace: weka-axon-test
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
`weka-axon-test` namespace.

Apply:

```bash
kubectl apply -f manifests/test/pvc.yaml
```

And check that it was created:

```bash
kubectl get pvc -n weka-axon-test

NAME             STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS                  VOLUMEATTRIBUTESCLASS   AGE
pvc-wekafs-dir   Pending                                      storageclass-wekafs-dir-api   <unset>                 19s
```

Status is **PENDING** because of `WaitForFirstConsumer`. It will
bind once a pod references the PVC.

## 10. Create Test Pod

Deploy a pod that mounts the PVC and writes test data:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: weka-axon-app
  namespace: weka-axon-test
spec:
  nodeSelector:
    weka.io/supports-clients: "true"
  tolerations:
    - key: "weka.io/axon"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
  containers:
    - name: test
      image: busybox:1.37.0
      command:
        - sh
        - -c
        - |
          echo "hello from WEKA CSI" > /data/hello.txt
          ls -la /data
          cat /data/hello.txt
          sleep 3600
      volumeMounts:
        - name: weka-vol
          mountPath: /data
  volumes:
    - name: weka-vol
      persistentVolumeClaim:
        claimName: pvc-wekafs-dir
```

Deploy the application pod:

```bash
kubectl apply -f manifests/test/weka-app.yaml
```

You can check that application ran:

```bash
kubectl logs -n weka-axon-test weka-axon-app

total 4
d---------    1 root     root             0 Feb  5 13:34 .
drwxr-xr-x    1 root     root            63 Feb  5 13:34 ..
-rw-r--r--    1 root     root            20 Feb  5 13:34 hello.txt
hello from WEKA CSI
```

You can also now see that the PVC has been bound:

```bash
kubectl get pvc -n weka-axon-test

NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                  VOLUMEATTRIBUTESCLASS   AGE
pvc-wekafs-dir   Bound    pvc-7fc58fbf-5156-4f6f-9b4a-4d7775f8a73e   10Gi       RWX            storageclass-wekafs-dir-api   <unset>                 9m36s
```

Verify persistence by deploying a second pod that reads the
same PVC from a different node:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: weka-axon-app-reader
  namespace: weka-axon-test
spec:
  nodeSelector:
    weka.io/supports-clients: "true"
  tolerations:
    - key: "weka.io/axon"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
  containers:
    - name: reader
      image: busybox:1.37.0
      command:
        - sh
        - -c
        - |
          set -eux
          echo "Reading data written by another pod:"
          cat /data/hello.txt
          sleep 3600
      volumeMounts:
        - name: weka-vol
          mountPath: /data
  volumes:
    - name: weka-vol
      persistentVolumeClaim:
        claimName: pvc-wekafs-dir
```

Deploy the pod:

```bash
kubectl apply -f manifests/test/weka-app-reader.yaml
```

and verify both application pods are running:

```bash
kubectl get pods -n weka-axon-test -o wide

NAME                   READY   STATUS    RESTARTS   AGE   IP           NODE                                       NOMINATED NODE   READINESS GATES
weka-axon-app          1/1     Running   0          12m   10.0.8.218   ip-10-0-8-123.us-west-2.compute.internal   <none>           <none>
weka-axon-app-reader   1/1     Running   0          14s   10.0.4.140   ip-10-0-4-159.us-west-2.compute.internal   <none>           <none>
```

Examine the logs from the reader pod:

```bash
kubectl logs -n weka-axon-test weka-axon-app-reader

+ echo 'Reading data written by another pod:'
Reading data written by another pod:
+ cat /data/hello.txt
hello from WEKA CSI
+ sleep 3600
```

---

## Automated Deployment

The `deploy.sh` script automates the full deployment: operator
install, ensure-nics, sign-drives, WekaCluster, WekaClient,
StorageClass, and a test pod. It waits for each step to
complete before proceeding.

```bash
./deploy.sh <cluster-name> <quay-username> <quay-password>
```

Arguments can also be passed as environment variables:

| Variable | Description |
| ---------- | ------------- |
| `CLUSTER_NAME` | EKS cluster name |
| `QUAY_USERNAME` | Quay.io username |
| `QUAY_PASSWORD` | Quay.io password |
| `WEKA_OPERATOR_VERSION` | Operator chart version (default: `v1.11.0`) |

To remove everything:

```bash
./deploy.sh --cleanup <cluster-name>
```

Run `./deploy.sh --help` for all options.

---

## Cleanup

### Remove WEKA Components

```bash
kubectl delete namespace weka-axon-test
kubectl delete storageclass storageclass-wekafs-dir-api
kubectl delete wekaclient -n weka-operator-system --all
kubectl delete wekacluster -n weka-operator-system --all
kubectl delete wekapolicy -n weka-operator-system --all
helm uninstall weka-operator -n weka-operator-system
kubectl delete namespace weka-operator-system
```

### Destroy Infrastructure

```bash
# From the module root (weka-axon/)
(cd terraform && terraform destroy)
```
