# WEKA on Amazon EKS

Deploy WEKA distributed storage with Amazon EKS using the WEKA Operator.

<p align="center">
  <img src="img/weka-eks-architecture.png" alt="WEKA + EKS Architecture" width="700">
</p>

## Deployment Models

### [weka-dedicated](weka-dedicated/)

A WEKA storage cluster is created with dedicated backend instances.
EKS worker nodes run WEKA client containers that connect to the
backend over the network. Applications access WEKA storage via the
CSI plugin and PersistentVolumeClaims.

### [weka-axon](weka-axon/)

WEKA backend and client processes run together on the same EKS
nodes. Each node contributes local NVMe storage to the distributed
filesystem while also running application workloads.

### [hyperpod-dedicated](hyperpod-dedicated/)

Similar to weka-dedicated, with a standalone WEKA storage cluster
and an EKS cluster for worker nodes and application pods. However,
client instances are provisioned and managed by SageMaker HyperPod,
and then added to the EKS cluster as worker nodes.

### [hyperpod-axon](hyperpod-axon/)

Similar to weka-axon, but SageMaker HyperPod provisions the
underlying EC2 instances. Those instances are added to an EKS
cluster, where they're used for deploying both the WEKA cluster
and worker pods.

## Deployment

See the README in each deployment model for detailed instructions.
Each module is a standalone deployment; you can create a fully
working WEKA + EKS cluster using the Terraform and other
code/instructions in each section.

Shared Terraform modules (e.g., [EKS](modules/eks/)) live in
[modules/](modules/) and are referenced by each deployment model.

### Prerequisites

* AWS CLI configured
* Terraform >= 1.5
* kubectl, Helm 3.x
* WEKA download token from [get.weka.io](https://get.weka.io)
* Quay.io credentials for WEKA images

### How It Works

WEKA integrates with Kubernetes using the standard CSI
(Container Storage Interface) pattern:

```text
┌──────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                           │
│                                                                      │
│  1. WEKA Operator          2. CSI Plugin           3. Your Pods      │
│  ┌─────────────────┐       ┌─────────────────┐     ┌──────────────┐  │
│  │ Deploys WEKA    │       │ Provisions PVs  │     │ Mount WEKA   │  │
│  │ client containers│  ──▶ │ from WEKA       │ ──▶ │ via PVC      │  │
│  │ on selected nodes│      │ filesystem      │     │              │  │
│  └─────────────────┘       └─────────────────┘     └──────────────┘  │
│         │                                                            │
│         ▼                                                            │
│  ┌─────────────────┐                                                 │
│  │ WekaClient CRD  │  Runs WEKA client process on nodes with         │
│  │                 │  label: weka.io/supports-clients=true           │
│  └─────────────────┘                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

### Deployment Flow

The general flow for a deployment is:

1. Deploy Terraform

   * A `terraform.tfvars.example` is provided as guide
   * The included Terraform builds a dedicated WEKA cluster
     and/or an EKS cluster, depending on the deployment type
   * Assumes some existing infrastructure (e.g. VPC, subnets)

2. Install the WEKA Kubernetes operator

   * A helm chart is available for installing the operator

3. Deploy WEKA custom resources

   * Core manifests are provided for creating the WEKA
     storage cluster
   * `WekaCluster` and `WekaClient` CRs

4. Install CSI plugin

   * Can be installed as part of the operator or separately

5. Set up test application to consume WEKA storage

   * Examples are provided for creating a `StorageClass`
     and `PVC` that application pods can use
