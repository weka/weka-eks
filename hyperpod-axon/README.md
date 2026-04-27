# WEKA Axon on EKS with SageMaker HyperPod

<!-- TODO: Add architecture diagram -->

Deploy a converged WEKA cluster (backends + clients on the same nodes)
on SageMaker HyperPod instances joined to EKS.

**Key difference from weka-axon:** Axon nodes are managed by SageMaker
HyperPod instead of EKS managed node groups. HyperPod handles instance
provisioning, health monitoring, and automatic node recovery.

**Key difference from hyperpod-dedicated:** There is no external WEKA
backend. The HyperPod nodes ARE the WEKA cluster -- they run both
backend containers (drive + compute) and client containers.

## Architecture

- **EKS cluster** -- System nodes only (CoreDNS, kube-proxy,
  WEKA operator, CSI controller)
- **HyperPod** -- Axon nodes running WEKA backend containers,
  client containers, and application workloads
- **NIC annotator** -- DaemonSet bridging HyperPod NIC config
  with WEKA operator expectations

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured
- `kubectl` and `helm` installed
- Quay.io credentials for WEKA container images
- An existing S3 bucket for HyperPod lifecycle scripts

## Directory Structure

```text
hyperpod-axon/
  terraform/
    eks/             EKS cluster (system nodes only)
    hyperpod/        SageMaker HyperPod cluster + lifecycle scripts
  scripts/
    on_create.sh                Lifecycle entrypoint
    on_create_main.sh           Containerd/kubelet + WEKA setup
    configure-weka-hugepages.sh Hugepages at boot
    configure-hyperpod-nics.py  Move NICs from SageMaker namespace
    weka-config.env.tftpl       Terraform template for WEKA config
  manifests/
    core/                       WekaCluster, WekaClient, sign-drives,
                                operator values, NIC annotator, StorageClass
    test/                       PVC + test pods
```

## Deployment

All commands assume you are in the `hyperpod-axon/` directory.

### 1. Deploy EKS Cluster

```bash
cd terraform/eks
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init && terraform apply

# Configure kubectl
$(terraform output -raw configure_kubectl)
```

### 2. Deploy HyperPod Cluster

```bash
cd ../hyperpod
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set eks_cluster_arn, subnet_ids,
# security_group_id, s3_bucket_name, instance_groups
terraform init && terraform apply
cd ../..
```

Wait for HyperPod nodes to join EKS:

```bash
kubectl get nodes --show-labels | grep hyperpod
```

### 3. Label HyperPod Nodes

HyperPod adds `sagemaker.amazonaws.com/compute-type: hyperpod`
automatically. Add the WEKA labels manually:

```bash
kubectl label node <node-name> \
  weka.io/supports-backends=true \
  weka.io/supports-clients=true
```

### 4. Install WEKA Operator

```bash
kubectl create namespace weka-operator-system

kubectl create secret docker-registry weka-quay-io-secret \
  --namespace weka-operator-system \
  --docker-server=quay.io \
  --docker-username="$QUAY_USERNAME" \
  --docker-password="$QUAY_PASSWORD"

helm upgrade --install weka-operator \
  oci://quay.io/weka.io/helm/weka-operator \
  --namespace weka-operator-system \
  --version v1.11.0 \
  --set imagePullSecret=weka-quay-io-secret \
  -f manifests/core/values-weka-operator.yaml \
  --wait
```

### 5. Deploy NIC Annotator

```bash
kubectl apply -f manifests/core/nic-annotator-rbac.yaml
kubectl apply -f manifests/core/nic-annotator-daemonset.yaml
```

Verify annotations:

```bash
kubectl get nodes -l sagemaker.amazonaws.com/compute-type=hyperpod \
  -o custom-columns=NAME:.metadata.name,NICS:.status.capacity.weka\\.io/nics
```

### 6. Verify Hugepages

```bash
kubectl get nodes -l weka.io/supports-backends=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi
```

### 7. Sign Drives

> **Note:** Sign-drives requires privileged access to local NVMe drives.
> Verify this works on your HyperPod instance type before proceeding.

```bash
kubectl apply -f manifests/core/sign-drives.yaml
```

### 8. Deploy WekaCluster and WekaClient

Edit `manifests/core/weka-cluster.yaml` to match your instance type
(adjust `computeContainers`, `computeCores`, `driveContainers`,
`driveCores`), then apply:

```bash
kubectl apply -f manifests/core/weka-cluster.yaml
kubectl apply -f manifests/core/weka-client.yaml
```

Monitor cluster formation:

```bash
kubectl get wekacluster -n weka-operator-system -w
kubectl get wekaclient -n weka-operator-system -w
```

### 9. Create StorageClass

```bash
kubectl apply -f manifests/core/storageclass-weka.yaml
```

### 10. Test

```bash
kubectl create namespace weka-axon-test
kubectl apply -f manifests/test/pvc.yaml
kubectl apply -f manifests/test/weka-writer.yaml

kubectl logs -n weka-axon-test weka-writer
```

## Resource Sizing

Container counts, cores, and hugepages depend on instance type.
The WEKA operator v1.11.0 auto-calculates compute hugepages from
drive capacity, but nodes must have enough total hugepages
pre-allocated at boot.

### Hugepages Formula (2 MiB pages)

| Role | Per core |
| ------- | -------- |
| Compute | 3 GiB = 1536 pages |
| Drive | 1.5 GiB = 768 pages |
| Client | 1.5 GiB = 768 pages |

Total pages = (compute_containers x compute_cores x 1536) +
(drive_containers x drive_cores x 768) + (client_cores x 768)

### Example: i3en.12xlarge (testing)

- 6 compute x 2 cores = 12 compute cores -> 18432 pages
- 6 drive x 2 cores = 12 drive cores -> 9216 pages
- 1 client core -> 768 pages
- Total = 28416 pages (~55 GiB)

In practice, the operator manages per-pod hugepages allocation.
The lifecycle script pre-allocates a node-level pool. The testing
value of 5376 pages works for i3en because the operator v1.11.0
dynamically sizes compute containers.

### NICs

Backend nodes typically need 1 NIC per DPDK core. With 6 compute +
6 drive containers at 2 cores each, 7 NICs is a reasonable default
for testing. Adjust based on instance ENI limits and WEKA config.

<!-- TODO: Add an "Instance Type Reference" appendix here when this
     module is built out. Resource planning matters more for axon
     (backends + clients on same nodes) than for hyperpod-dedicated,
     so the table earns its place here.

     Columns to include: vCPUs, max network cards, max ENIs.
     Note that EFA cards can be configured as standard EFA (with
     ENA component, has IP, usable by WEKA via DPDK) or EFA-only
     (no IP, RDMA only — not usable by WEKA). The first EFA must
     be standard. Verify on each new instance type before deploying.

     We dropped this from the hyperpod-dedicated README because
     dedicated clients only need a few NICs regardless of instance
     type. Axon is different. -->

## How NIC Configuration Works

Same approach as hyperpod-dedicated:

1. **Lifecycle script** (`configure-hyperpod-nics.py`) runs at boot,
   moves NICs from `sagemaker_agent_namespace` to the default
   namespace, assigns IPs via IMDS, writes JSON to
   `/var/lib/weka/hyperpod-nics.json`
2. **NIC annotator DaemonSet** reads JSON and annotates nodes with
   `weka.io/weka-nics` + patches `weka.io/nics` capacity
3. **WEKA operator** sees annotated nodes and schedules containers

## Node Replacement

When SageMaker replaces a failed node:

1. New instance runs lifecycle scripts (hugepages + NICs configured)
2. Node joins EKS with `sagemaker.amazonaws.com/compute-type: hyperpod`
3. DaemonSet annotates node from NIC JSON
4. Label the node with `weka.io/supports-backends=true` and
   `weka.io/supports-clients=true`
5. WEKA operator reschedules backend + client containers

## Cleanup

```bash
# Remove Kubernetes resources (reverse order)
kubectl delete -f manifests/test/
kubectl delete -f manifests/core/weka-client.yaml
kubectl delete -f manifests/core/weka-cluster.yaml
kubectl delete -f manifests/core/sign-drives.yaml
helm uninstall weka-operator -n weka-operator-system
kubectl delete -f manifests/core/nic-annotator-daemonset.yaml
kubectl delete -f manifests/core/nic-annotator-rbac.yaml

# Destroy infrastructure (run each from the module root)
(cd terraform/hyperpod && terraform destroy)
(cd terraform/eks && terraform destroy)
```

## Versions

| Component | Version |
| --------- | ------- |
| WEKA container | 4.4.21.2 |
| WEKA operator | v1.11.0 |
| Kubernetes | 1.33 |
| Terraform | >= 1.5 |
| busybox | 1.37.0 |
