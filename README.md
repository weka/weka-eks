# WEKA on Amazon EKS

Deploy WEKA distributed storage with Amazon EKS.

## Architecture Overview

<!-- TODO: Add architecture diagram -->
<!-- ![Architecture](img/architecture.png) -->

```
┌─────────────────────────────────────────────────────────────┐
│                        EKS Cluster                          │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │   System Nodes  │  │  WEKA Client    │                   │
│  │                 │  │     Nodes       │                   │
│  │  - CoreDNS      │  │                 │                   │
│  │  - Operator     │  │  ┌───────────┐  │                   │
│  │  - CSI Plugin   │  │  │WEKA Client│  │                   │
│  │                 │  │  │ Container │──┼───┐               │
│  └─────────────────┘  │  └───────────┘  │   │               │
│                       └─────────────────┘   │               │
└─────────────────────────────────────────────┼───────────────┘
                                              │ DPDK/UDP
┌─────────────────────────────────────────────┼───────────────┐
│                   WEKA Backend Cluster      │               │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌─────▼┐ ┌──────┐     │
│  │  i3en │ │  i3en │ │  i3en │ │  i3en │ │  i3en │ │  i3en │     │
│  │  node │ │  node │ │  node │ │  node │ │  node │ │  node │     │
│  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘     │
│                        NVMe Storage                         │
└─────────────────────────────────────────────────────────────┘
```

## Deployment Models

### [weka-dedicated](weka-dedicated/)

Separate WEKA storage cluster with dedicated backend instances (i3en). EKS worker nodes run WEKA client containers that connect to the backend over the network. Applications access WEKA storage via the CSI plugin and PersistentVolumeClaims.

**Best for**: Production workloads, independent scaling of compute and storage.

### [weka-converged](weka-converged/)

WEKA backend and client processes run together on the same EKS nodes. Each node contributes local NVMe storage to the distributed filesystem while also running application workloads.

**Best for**: Development/test environments, simplified operations.

### [hyperpod-dedicated](hyperpod-dedicated/)

Similar to weka-dedicated, but client node instances are provisioned and managed by SageMaker HyperPod. HyperPod handles instance lifecycle and health monitoring, then nodes join the EKS cluster for workload scheduling.

**Best for**: ML training workloads requiring managed infrastructure with high-performance storage.

### [hyperpod-converged](hyperpod-converged/)

Similar to weka-converged, but all underlying instances (both WEKA backends and clients) are provisioned and managed by SageMaker HyperPod.

**Best for**: Fully managed ML infrastructure with converged storage. *(Experimental)*

## Quick Start

See the README in each deployment model for detailed instructions.

For **weka-dedicated**:

```bash
cd weka-dedicated

# 1. Deploy infrastructure
cd terraform/weka-backend && terraform apply
cd ../eks && terraform apply

# 2. Configure manifests
cp manifests/core/weka-client.yaml.example manifests/core/weka-client.yaml
cp manifests/core/csi-wekafs-api-secret.yaml.example manifests/core/csi-wekafs-api-secret.yaml
# Edit with your values...

# 3. Deploy WEKA operator, clients, and CSI
./deploy.sh <cluster-name> <quay-username> <quay-password>
```

## Prerequisites

- AWS CLI configured
- Terraform 1.5+
- kubectl, Helm 3.x
- WEKA download token ([get.weka.io](https://get.weka.io))
- Quay.io credentials for WEKA images (contact WEKA)

## How It Works

WEKA integrates with Kubernetes using the standard CSI (Container Storage Interface) pattern:

```text
┌──────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                           │
│                                                                      │
│  1. WEKA Operator          2. CSI Plugin           3. Your Pods     │
│  ┌─────────────────┐       ┌─────────────────┐     ┌──────────────┐ │
│  │ Deploys WEKA    │       │ Provisions PVs  │     │ Mount WEKA   │ │
│  │ client containers│  ──▶  │ from WEKA       │ ──▶ │ via PVC      │ │
│  │ on selected nodes│       │ filesystem      │     │              │ │
│  └─────────────────┘       └─────────────────┘     └──────────────┘ │
│         │                                                            │
│         ▼                                                            │
│  ┌─────────────────┐                                                 │
│  │ WekaClient CRD  │  Runs WEKA client process on nodes with        │
│  │                 │  label: weka.io/supports-clients=true          │
│  └─────────────────┘                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

### Deployment Flow

1. **Install WEKA Operator** - Helm chart that manages WEKA components
2. **Deploy WekaClient** - Operator starts WEKA client containers on labeled nodes, connecting them to the WEKA backend cluster
3. **Install CSI Plugin** - Helm chart that enables Kubernetes to provision volumes from WEKA
4. **Create StorageClass** - Defines how PVs are provisioned (filesystem, mount options)
5. **Create PVCs** - Applications request storage; CSI plugin creates directories on WEKA and mounts them into pods

### WEKA Operator CRDs

| CRD | Purpose |
|-----|---------|
| `WekaClient` | Deploys WEKA client containers on selected nodes |
| `WekaPolicy` | Runs one-time node operations (e.g., `ensure-nics` to create dedicated NICs) |
| `WekaContainer` | Status tracking for client containers (managed by operator) |

### Storage Flow

```yaml
# StorageClass defines provisioning parameters
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: storageclass-wekafs-dir
provisioner: csi.weka.io
parameters:
  volumeType: dir/v1
  filesystemName: default
---
# PVC requests storage from the StorageClass
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  storageClassName: storageclass-wekafs-dir
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 10Gi
---
# Pod mounts the PVC
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: app
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: my-data
```
