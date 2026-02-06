# WEKA Axon on Amazon EKS

This document provides a walkthrough for deploying WEKA Axon on Amazon EKS using Terraform and the WEKA Kubernetes Operator.

## What is WEKA Axon?

WEKA Axon is WEKA’s combined deployment model, where:

* WEKA backends (drives + compute)
* WEKA clients
* Applications

all run on the same hardware; in the context of EKS it means they all run on the **same Kubernetes worker nodes**. This model is ideal for EC2 instances with large amounts of local NVMe storage, allowing the WEKA filesystem to be built directly from local disks while being consumed by Kubernetes workloads via CSI.

## Architecture Overview

### Node Group Model

The EKS cluster in this example uses **two distinct node groups**, one for handling control-plane functions and another for the WEKA storage cluster and application pods. This separation isn't strictly required for WEKA (we're doing it for simplicity in this walkthrough). Node groups may be structured differently for operational or organizational reasons. The main thing is that a node group is constructed out of nodes with local NVMe storage, which will be used by the WEKA operator for deploying the storage cluster.

#### 1. System Node Group

**Purpose**: Run Kubernetes and WEKA control-plane components.

Characteristics:

* No WEKA-specific taints
* No WEKA scheduling labels required
* Smaller instance types

Runs:

* Core Kubernetes components (CoreDNS, kube-proxy, AWS VPC CNI)
* Cluster add-ons (metrics, logging, etc.)
* WEKA operator controller
* CSI controller pods

#### 2. Axon Node Group

Purpose: Run WEKA storage components and application workloads.

Characteristics:

* Large EC2 instances with local NVMe (e.g. p5.48xlarge)
* Labeled to support both WEKA backends and clients
* Tainted to prevent accidental scheduling of unrelated workloads
* IMDS hop limit set to **2** (required for NIC allocation)
* Kubelet CPU settings applied at node bootstrap

Runs:

* WEKA drive containers
* WEKA compute containers
* WEKA client containers
* CSI node DaemonSet
* Application pods that mount WEKA volumes

## Prerequisites

* AWS account with permissions to create EKS, EC2, IAM, VPC resources
* Terraform >= 1.5
* kubectl
* Helm 3.x
* Quay.io credentials for WEKA images and Helm charts

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
    hugepages-daemonset.yaml
    ensure-nics.yaml
    sign-drives.yaml
    weka-cluster.yaml
    weka-client.yaml
  test/
    storageclass-weka.yaml
    pvc.yaml
    weka-app.yaml
    weka-app-reader.yaml
```

## 1. Deploy EKS Infrastructure (Terraform)

> **Working directory:** `terraform/`

### 1.1 Configure Terraform

The example `terraform.tfvars` file includes default values to get you started. The main variables to review are:

* `region`
* `cluster_name`
* `vpc_id`, `subnet_ids`
* `enable_ssm_access`

SSM access is enabled instead of SSH keys to simplify node access for debugging.

### 1.2 Node Groups

Node groups are defined using a map, allowing us to easily configure different settings for different node groups.

Example:

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
    enable_nodeadm_config = false
  }

  storage = {
    instance_types = ["i3en.12xlarge"]
    desired_size   = 6
    min_size       = 6
    max_size       = 12

    disk_size = 200
    imds_hop_limit_2 = true
    ami_type = "AL2023_x86_64_STANDARD"
    enable_nodeadm_config = true

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

Here we define both our system nodes and storage nodes that make up the WEKA Axon cluster. The key differences between the two maps:

* Instance type and AMI
* nodeadm configuration (controls kubelet settings)
* Labels and taints to control where WEKA pods are scheduled

### 1.3 Terraform Deployment

Once you've configured `terraform.tfvars` you can create the EKS cluster:

```bash
terraform init
terraform apply
```

That process should take approximately 10-15 minutes.
Once the cluster is created you can configure `kubectl` to access it:

```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

Verify nodes:

```bash
kubectl get nodes -o wide
 
NAME                                        STATUS   ROLES    AGE     VERSION               INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
ip-10-0-0-183.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   10.0.0.183    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-10-107.us-west-2.compute.internal   Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   10.0.10.107   <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-10-68.us-west-2.compute.internal    Ready    <none>   3h13m   v1.33.5-eks-ecaa3a6   10.0.10.68    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-11-31.us-west-2.compute.internal    Ready    <none>   3h13m   v1.33.5-eks-ecaa3a6   10.0.11.31    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-11-54.us-west-2.compute.internal    Ready    <none>   3h13m   v1.33.5-eks-ecaa3a6   10.0.11.54    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-7-157.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   10.0.7.157    <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-8-68.us-west-2.compute.internal     Ready    <none>   3h13m   v1.33.5-eks-ecaa3a6   10.0.8.68     <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
ip-10-0-8-81.us-west-2.compute.internal     Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   10.0.8.81     <none>        Amazon Linux 2023.10.20260105   6.12.63-84.121.amzn2023.x86_64    containerd://2.1.5
```

```bash
kubectl get nodes -L weka.io/supports-backends,weka.io/supports-clients

NAME                                        STATUS   ROLES    AGE     VERSION               SUPPORTS-BACKENDS   SUPPORTS-CLIENTS
ip-10-0-0-183.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6
ip-10-0-10-107.us-west-2.compute.internal   Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   true                true
ip-10-0-10-68.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   true                true
ip-10-0-11-31.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   true                true
ip-10-0-11-54.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   true                true
ip-10-0-7-157.us-west-2.compute.internal    Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6
ip-10-0-8-68.us-west-2.compute.internal     Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   true                true
ip-10-0-8-81.us-west-2.compute.internal     Ready    <none>   3h14m   v1.33.5-eks-ecaa3a6   true                true
```

## 2. Install WEKA Operator (with embedded CSI)

> **Working directory:** `manifests/core/`

The [WEKA Operator](https://docs.weka.io/kubernetes/weka-operator-deployments) automates deployment, scaling, and lifecycle management of a WEKA storage system inside a Kubernetes cluster. It introduces Kubernetes Custom Resources (e.g., WekaCluster and WekaClient) that let you declaratively provision and manage WEKA storage components in Kubernetes workloads.

In addition to the WEKA operator, we'll also install the [WEKA CSI plugin](https://docs.weka.io/appendices/weka-csi-plugin). It provides a CSI driver for Kubernetes that lets pods create and mount persistent volumes on WEKA storage. We could do this separately, but doing it here simplifies some of the steps (like secret creation and `StorageClass` definitions).

To start, create a namespace for the operator:

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
  --version v1.9.1 \
  --set imagePullSecret=weka-quay-io-secret \
  --set csi.installationEnabled=true \
  --wait
```

Output:

```bash
Release "weka-operator" does not exist. Installing it now.
Pulled: quay.io/weka.io/helm/weka-operator:v1.9.1
Digest: sha256:065e6e8d3c7f3a9fcaf028e68feb65c67e822718947e5e848abb6a4370ab9e37
NAME: weka-operator
LAST DEPLOYED: Wed Jan 28 09:06:43 2026
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

Before we start deploying the WEKA cluster and clients, we need to plan what resources we allocate to the cluster. The storage cluster is composed of the following:

* Compute processes: Handles filesystems, cluster-level functions, and IO from clients
* Drive processes: Manages SSD drives and IO operations to the drives
* Frontend (client) processes: Manages POSIX client access and coordinates IO operations with compute and drive processes

We need to allocate CPU cores and network devices to each of these processes. In a dedicated WEKA cluster we would normally define the cluster and client resources separately; however, because we are creating an Axon cluster, the node resources will be used by both the cluster processes and the application(s) that will use the WEKA storage cluster.

For resource planning, we recommend:

* **1 drive process** per NVMe drive, up to 6 SSDs
  * Above 6 SSDs, use 1 drive process per 2 SSDs
* A ratio of **2 compute processes** per drive process
* **1 frontend process** per node
* Memory requirements:
  * 2.8 GB fixed
  * 2.2 GB per frontend process
  * 3.9 GB per compute process
  * 2 GB per drive process

We also need to allocate network resources, and in AWS that means creating additional network interfaces (ENIs) and assigning them to WEKA processes. Ideally we would allocate 1 ENI per WEKA process; however, in the cloud we are typically limited by the number of available interfaces. And because we are deploying an Axon cluster in this example, we are further restricted on available network devices; we need to leave some ENIs available for the application to access the WEKA cluster via DPDK for performance. Keep in mind that for most production Axon deployments, users are typically using larger GPU instances (e.g., `p5.48xlarge` or `p6-b200.48xlarge`) which have a large number of available ENIs.

The Terraform config provided in this repo uses 6 of the `i3en.12xlarge` instances for the cluster nodes. You are welcome to use a different instance if you prefer, but for the purposes of our example we'll plan our WEKA resources using the specs of the `i3en.12xlarge` instance:

* 48 vCPU
* 384 GiB memory
* 4 x 7500 GB NVMe
* 50 Gbps network bandwidth (Maximum of **8 network interfaces**)

Given the number of available ENIs on the `i3en.12xlarge`, we will scale back the number of cores we assign to the compute and drive processes. We also need to account for:

* 1 ENI for management (this is the default interface that is created when launching the instance)
* 1 ENI used by EKS (part of the Amazon VPC CNI)
* 1 ENI for use in the client application pod

So, for our example, we have the following, **per-node** resource requirements:

* WEKA Cluster:
  * 4 NVMe
  * 2 cores + 2 ENIs for drive processes
  * 2 cores + 2 ENIs for compute processes
  * 1 core + 1 ENI for frontend/client process
  * 2 ENIs for management and EKS
  * 16.8 GB RAM
* Application Pod:
  * 1 core + 1 ENI for application (using DPDK)

### 3.1 Configure Huge Pages

WEKA uses hugepages for performance, and we need to allocate pages at the node level for each of the WEKA processes:

The recommended hugepage memory sizing is:

* Compute core: **3 GiB** hugepages
* Drive core: **1.5 GiB** hugepages
* Frontend core: **1.5 GiB** hugepages

To calculate the required hugepages:

1. Compute total GiB:

   `GiB_total = 3*(compute_cores) + 1.5*(drive_cores) + 1.5*(frontend_cores)`

2. Convert GiB to number of **2MiB** hugepages:

   1 GiB = 1024 MiB, and each hugepage is 2 MiB → **512 hugepages per GiB**

   `nr_hugepages = GiB_total * 512`

**Example:**

* 2 compute cores, 2 drive cores, 1 frontend core
* GiB_total = 3\*2 + 1.5\*2 + 1.5\*1 = **10.5 GiB**  
* nr_hugepages = 10.5*512 = **5376**

Set this value in `manifests/core/hugepages-daemonset.yaml`:

```yaml
data:
  HUGEPAGES_COUNT: "5376"
```

Apply the DaemonSet:

```bash
kubectl apply -f hugepages-daemonset.yaml
```

Verify allocation:

```bash
kubectl get nodes -l weka.io/supports-backends=true \
  -o custom-columns=NAME:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi

NAME                                       HUGEPAGES
ip-10-0-2-195.us-west-2.compute.internal   10752Mi
ip-10-0-3-221.us-west-2.compute.internal   10752Mi
ip-10-0-4-159.us-west-2.compute.internal   10752Mi
ip-10-0-7-149.us-west-2.compute.internal   10752Mi
ip-10-0-8-123.us-west-2.compute.internal   10752Mi
ip-10-0-8-94.us-west-2.compute.internal    10752Mi
```

## 4. Configure NICs

WEKA uses [DPDK](https://docs.weka.io/weka-system-overview/networking-in-wekaio) to bypass the kernel stack, resulting in high-performance, low-latency packet processing. This also means we need to allocate networking devices to individual cores and WEKA processes. DPDK is supported in AWS, but we need to create and attach additional network interfaces. The WEKA operator uses a policy to check for NICs and create them if necessary.

We can use a `WekaPolicy` to handle creating additional ENIs and attaching them to the underlying EC2 instance. The operator will make these available at the node level for pods to use.

Based on our example instance type, `i3en.12xlarge`, and the resource planning we did earlier, we'll be using the maximum of 8 ENIs for this instance (6 for the WEKA cluster, 1 management, and 1 for the application pod). The instance has 1 network interface created by default, so we need to specify that 7 additional ENIs are created.

An example policy is provided:

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaPolicy
metadata:
  name: ensure-nics-policy
  namespace: weka-operator-system
spec:
  type: "ensure-nics"
  image: "quay.io/weka.io/weka-in-container:4.4.10.200"
  imagePullSecret: "weka-quay-io-secret"
  payload:
    ensureNICsPayload:
      type: aws
      nodeSelector:
        weka.io/supports-backends: "true"
      dataNICsNumber: 7
```

`dataNICsNumber` is the number of additional ENIs to attach beyond the primary ENI created at instance launch. For deploying in AWS, it's important that `spec.payload.type` is set to `aws`. Also, we need to make sure the `nodeSelector` parameter is set so that the ENIs will be created on the correct nodes.

Apply the policy:

```bash
kubectl apply -f ensure-nics.yaml
```

We can check the output after a few minutes to see if the network interfaces have been created:

```bash
kubectl describe wekapolicy ensure-nics-policy -n weka-operator-system

Name:         ensure-nics-policy
Namespace:    weka-operator-system
Labels:       <none>
Annotations:  <none>
API Version:  weka.weka.io/v1alpha1
Kind:         WekaPolicy
Metadata:
  Creation Timestamp:  2026-02-04T21:24:33Z
  Generation:          1
  Resource Version:    351081
  UID:                 e62c0b32-5855-4ca6-afd3-deee192e4d72
Spec:
  Image:              quay.io/weka.io/weka-in-container:4.4.10.200
  Image Pull Secret:  weka-quay-io-secret
  Payload:
    Ensure Ni Cs Payload:
      Data Ni Cs Number:  7
      Node Selector:
        weka.io/supports-backends:  true
      Type:                         aws
    Interval:                       5m
  Type:                             ensure-nics
Status:
  Last Run Time:  2026-02-05T14:25:57Z
  Result:         {"results":{"ip-10-0-2-195.us-west-2.compute.internal":{"err":null,"nics":[{"mac_address":"06:b7:0a:1e:a3:1b","primary_ip":"10.0.2.194","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:80:dd:ea:01:fb","primary_ip":"10.0.3.84","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:1d:ab:d1:d1:ed","primary_ip":"10.0.2.75","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:21:a6:eb:2e:1f","primary_ip":"10.0.2.24","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:74:2e:60:56:e7","primary_ip":"10.0.2.99","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:dc:d8:c0:8f:87","primary_ip":"10.0.0.15","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:61:e0:2a:8a:bd","primary_ip":"10.0.0.4","subnet_cidr_block":"10.0.0.0/22"}],"ensured":true},"ip-10-0-3-221.us-west-2.compute.internal":{"err":null,"nics":[{"mac_address":"06:7a:19:1a:bc:91","primary_ip":"10.0.1.64","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:c4:07:83:53:61","primary_ip":"10.0.2.66","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:e3:77:dc:ba:2f","primary_ip":"10.0.1.6","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:9f:cb:62:d7:bf","primary_ip":"10.0.2.40","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:d0:7e:bb:36:9f","primary_ip":"10.0.3.7","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:11:b6:b6:e3:83","primary_ip":"10.0.2.237","subnet_cidr_block":"10.0.0.0/22"},{"mac_address":"06:86:61:61:73:3d","primary_ip":"10.0.2.74","subnet_cidr_block":"10.0.0.0/22"}],"ensured":true},"ip-10-0-4-159.us-west-2.compute.internal":{"err":null,"nics":[{"mac_address":"02:d3:87:ab:5f:21","primary_ip":"10.0.5.2","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:b9:c0:10:0c:39","primary_ip":"10.0.7.186","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:55:79:8d:de:a9","primary_ip":"10.0.4.218","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:ea:7d:a6:03:b1","primary_ip":"10.0.5.113","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:15:8e:ef:59:7d","primary_ip":"10.0.6.28","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:b5:12:ca:fb:1d","primary_ip":"10.0.6.6","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:20:86:55:3c:11","primary_ip":"10.0.6.67","subnet_cidr_block":"10.0.4.0/22"}],"ensured":true},"ip-10-0-7-149.us-west-2.compute.internal":{"err":null,"nics":[{"mac_address":"02:dc:ca:0f:fc:eb","primary_ip":"10.0.6.130","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:fd:8a:0a:7c:43","primary_ip":"10.0.4.128","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:e8:e2:2c:48:b5","primary_ip":"10.0.5.101","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:5c:5c:40:07:07","primary_ip":"10.0.7.124","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:7e:20:c6:f7:19","primary_ip":"10.0.6.59","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:1c:6f:2d:0e:75","primary_ip":"10.0.6.68","subnet_cidr_block":"10.0.4.0/22"},{"mac_address":"02:2c:3e:a0:d6:f9","primary_ip":"10.0.6.110","subnet_cidr_block":"10.0.4.0/22"}],"ensured":true},"ip-10-0-8-123.us-west-2.compute.internal":{"err":null,"nics":[{"mac_address":"0a:6a:04:68:c7:d7","primary_ip":"10.0.8.128","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:74:ce:74:37:95","primary_ip":"10.0.9.231","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:82:d4:38:0a:31","primary_ip":"10.0.8.116","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:7a:b3:9b:fb:23","primary_ip":"10.0.9.68","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:6b:6e:49:9a:e7","primary_ip":"10.0.11.44","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:d8:78:e6:ef:55","primary_ip":"10.0.10.47","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:31:2c:f4:fb:55","primary_ip":"10.0.9.18","subnet_cidr_block":"10.0.8.0/22"}],"ensured":true},"ip-10-0-8-94.us-west-2.compute.internal":{"err":null,"nics":[{"mac_address":"0a:c4:6c:cc:74:0f","primary_ip":"10.0.9.1","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:85:e3:f6:d7:37","primary_ip":"10.0.11.61","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:e5:c9:9c:bf:49","primary_ip":"10.0.8.55","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:4f:67:51:b3:af","primary_ip":"10.0.10.122","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:59:9d:47:a7:df","primary_ip":"10.0.8.195","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:ce:fb:eb:98:87","primary_ip":"10.0.8.74","subnet_cidr_block":"10.0.8.0/22"},{"mac_address":"0a:3f:b3:ff:d7:d1","primary_ip":"10.0.11.11","subnet_cidr_block":"10.0.8.0/22"}],"ensured":true}}}
  Status:         Done
Events:           <none>
```

If you want to simplify the output a bit and check each node:

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

Note that this will run every 5 minutes and check if there are nodes that need additional NICs created.

## 5. Prepare Drives

Local NVMe drives must be discovered and signed before they can be used by WEKA.

This guide uses an automated `WekaPolicy` to:

* Discover eligible drives
* Assign unique IDs
* Make them available to the cluster

It's also possible to do to this process manually with `WekaManualOperation`. This can be useful for certain situations such only allocating a portion of the local NVMe drives to WEKA. For more information, see the [WEKA documentation](https://docs.weka.io/kubernetes/weka-operator-deployments#id-5.-discover-drives-for-weka-cluster-provisioning).

An example policy is provided:

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

* `type`: We need to ensure this is set to `aws-all` for this deployment
* `nodeSelector`: Ensure this runs only on nodes that will be used for the WEKA storage cluster

Apply the policy:

```bash
kubectl apply -f sign-drives.yaml
```

We can check the status of the policy:

```bash
kubectl get wekapolicy sign-drives-policy -n weka-operator-system

NAME                 TYPE          STATUS   PROGRESS
sign-drives-policy   sign-drives   Done
```

And for more detail:

```bash
kubectl describe wekapolicy sign-drives-policy -n weka-operator-system

Name:         sign-drives-policy
Namespace:    weka-operator-system
Labels:       <none>
Annotations:  <none>
API Version:  weka.weka.io/v1alpha1
Kind:         WekaPolicy
Metadata:
  Creation Timestamp:  2026-02-04T21:28:12Z
  Generation:          1
  Resource Version:    355924
  UID:                 0d2c65bf-c1b5-47ad-a2b8-b39befe245aa
Spec:
  Payload:
    Interval:  5m
    Sign Drives Payload:
      Node Selector:
        weka.io/supports-backends:  true
      Type:                         aws-all
  Type:                             sign-drives
Status:
  Last Run Time:  2026-02-05T14:40:48Z
  Result:         {"message":"No new drives signed"}
  Status:         Done
Events:           <none>
```

## 6. Deploy WEKA Cluster

The `WekaCluster` custom resource defines the WEKA backend (drive + compute containers) and how it is scheduled onto Axon nodes.
At minimum, review the following fields in weka-cluster.yaml:

* `spec.dynamicTemplate`
  * `computeContainers`: Number of compute containers for the entire cluster (maximum 1 per node)
  * `computeCores`: Number of cores per compute container
  * `driveContainers`: Number of drive containers (maximum 1 per node)
  * `driveCores`: Number of cores per drive container
  * Using our example from the `hugepages` configuration section, we would have 3 `computeContainers` and 8 `driveContainers`
* `spec.nodeSelector`: The example manifest sets `weka.io/supports-backends: true` to ensure only specific nodes are used for the WekaCluster deployment
* `spec.rawTolerations`: The example manifest sets a taint, `weka.io/axon=true:NoSchedule`, so backend pods can be scheduled
* `spec.image` and `spec.imagePullSecret`: Make sure to set the correct image and version, and the secret storing the quay.io credentials
* `spec.network`: We set `udpMode: false` to make use of dedicated ENIs for performance

Based on our instance type `i3en.12xlarge` and the resource planning from earlier, here's an example `WekaCluster`:

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
    driveContainers: 6
    driveCores: 2
  image: quay.io/weka.io/weka-in-container:4.4.10.200
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
kubectl apply -f weka-cluster.yaml
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

The other custom resource we need to deploy is the `WekaClient`. This is equivalent to the front-end processes we would normally create in a dedicated WEKA cluster. As we are creating an Axon cluster, we will deploy the `WekaClient` to the same nodes as the `WekaCluster` CR. Here's an example manifest:

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
  image: quay.io/weka.io/weka-in-container:4.4.10.200
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

The main parameters to check are:

* `spec.coresNum`: Number of cores to allocate to the client process
* `spec.targetCluster`: Name and namespace of an existing `WekaCluster`

We also add the tolerations:

```yaml
rawTolerations:
    - key: "weka.io/axon"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
```

to allow the `WekaClient` CR to be deployed to the same nodes as the `WekaCluster` CR.

Apply the WekaClient manifest:

```bash
kubectl apply -f weka-client.yaml
```

Verify the client has deployed:

```bash
kubectl get wekaclient -n weka-operator-system

NAME                   STATUS    TARGET CLUSTER          CORES   CONTAINERS(A/C/D)
weka-axon-eks-client   Running   weka-axon-eks-cluster   1       6/6/6
```

## 8. Verify WEKA Processes

### Client verification

We can check that WEKA is running by executing `weka local ps` on one of the pods. First get a list of the client pods:

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
3dec9945aea2client  Running  True      0:04:32h  True        True        46001  822  Ready   4.4.10.200
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

You also need to retrieve the WEKA admin credentials (created automatically by the operator):

```bash
kubectl get secret -n weka-operator-system weka-cluster-weka-axon-eks-cluster \
  -o jsonpath='{.data.username}' | base64 -d; echo

kubectl get secret -n weka-operator-system weka-cluster-weka-axon-eks-cluster \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Once logged in you should see the cluster:

![WEKA Axon UI](../img/weka-axon/weka-axon-ui.png)

## 9. CSI Components

When the WEKA CSI plugin is installed, it provisions volumes using Kubernetes StorageClass objects. A StorageClass tells CSI what type of WEKA volume to create (directory/snapshot/filesystem-backed), which WEKA filesystem to use, and which credentials secret to use for API operations.

The WEKA operator we deployed earlier automatically created:

* CSI controller Deployment
* CSI node DaemonSet
* CSI API secret
* Default StorageClasses

We'll walk through creating another StorageClass, a PVC to access it, and a test pod to show how an application could access our WEKA Axon cluster.

### 9.1 API Secret

The WEKA CSI plugin uses an API-based communication model, where cluster endpoints + credentials are stored in a Kubernetes Secret referenced by the StorageClass. Because we had the WEKA operator handle the CSI plugin installation earlier, the API secret has already been created:

```bash
kubectl get secrets -n weka-operator-system | grep -i csi 

weka-csi-weka-axon-eks-cluster                       Opaque                           5      9h
```

We can inspect the contents of the secret:

```bash
kubectl get secret -n weka-operator-system  weka-csi-weka-axon-eks-cluster  -o yaml

apiVersion: v1
data:
  endpoints: MTAuMC44Ljk0OjE1MTAwLDEwLjAuNy4xNDk6MTUwMDAsMTAuMC44LjEyMzoxNTEwMCwxMC4wLjIuMTk1OjE1MDAwLDEwLjAuNC4xNTk6MTUwMDAsMTAuMC44Ljk0OjE1MDAwLDEwLjAuNy4xNDk6MTUxMDAsMTAuMC4zLjIyMToxNTAwMCwxMC4wLjMuMjIxOjE1MTAwLDEwLjAuOC4xMjM6MTUwMDAsMTAuMC40LjE1OToxNTEwMCwxMC4wLjIuMTk1OjE1MTAw
  organization: Um9vdA==
  password: <redacted>
  scheme: aHR0cHM=
  username: d2VrYWNzaWM0YzJmYWI5NjVjMA==
kind: Secret
metadata:
  creationTimestamp: "2026-02-04T21:40:29Z"
  name: weka-csi-weka-axon-eks-cluster
  namespace: weka-operator-system
  ownerReferences:
  - apiVersion: weka.weka.io/v1alpha1
    blockOwnerDeletion: true
    controller: true
    kind: WekaCluster
    name: weka-axon-eks-cluster
    uid: 95113f32-9a00-42a3-a451-c4c2fab965c0
  resourceVersion: "293077"
  uid: e8587dec-b3f1-4ac5-8768-02b125d1d3a9
type: Opaque
```

Note that the `data` values are base64-encoded:

```bash
kubectl get secret -n weka-operator-system weka-csi-weka-axon-eks-cluster \
  -o jsonpath='{.data.username}' | base64 --decode; echo

wekacsic4c2fab965c0
```

This is important, as you would need to ensure you correctly encode data values if you want to create your CSI secret (we'll stick with the one automatically created here for simplicity).

### 9.2 StorageClasses

> **Working directory:** `manifests/test/`

When the CSI plugin is enabled, the WEKA operator creates one or more StorageClasses that point to the WEKA cluster via a CSI secret.

List StorageClasses:

```bash
kubectl get storageclass | grep -i weka

weka-weka-axon-eks-cluster-weka-operator-system-default               weka-axon-eks-cluster.weka-operator-system.weka.io   Delete          Immediate              true                   13h
weka-weka-axon-eks-cluster-weka-operator-system-default-forcedirect   weka-axon-eks-cluster.weka-operator-system.weka.io   Delete          Immediate              true                   13h
```

We can inspect one of the StorageClasses:

```bash
kubectl describe storageclass weka-weka-axon-eks-cluster-weka-operator-system-default

Name:                  weka-weka-axon-eks-cluster-weka-operator-system-default
IsDefaultClass:        No
Annotations:           <none>
Provisioner:           weka-axon-eks-cluster.weka-operator-system.weka.io
Parameters:            capacityEnforcement=HARD,csi.storage.k8s.io/controller-expand-secret-name=weka-csi-weka-axon-eks-cluster,csi.storage.k8s.io/controller-expand-secret-namespace=weka-operator-system,csi.storage.k8s.io/controller-publish-secret-name=weka-csi-weka-axon-eks-cluster,csi.storage.k8s.io/controller-publish-secret-namespace=weka-operator-system,csi.storage.k8s.io/node-publish-secret-name=weka-csi-weka-axon-eks-cluster,csi.storage.k8s.io/node-publish-secret-namespace=weka-operator-system,csi.storage.k8s.io/node-stage-secret-name=weka-csi-weka-axon-eks-cluster,csi.storage.k8s.io/node-stage-secret-namespace=weka-operator-system,csi.storage.k8s.io/provisioner-secret-name=weka-csi-weka-axon-eks-cluster,csi.storage.k8s.io/provisioner-secret-namespace=weka-operator-system,filesystemName=default,mountOptions=,volumeType=dir/v1
AllowVolumeExpansion:  True
MountOptions:          <none>
ReclaimPolicy:         Delete
VolumeBindingMode:     Immediate
Events:                <none>
```

Now we'll create a StorageClass. An example config is provided in the repo:

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

Our StorageClass has the following properties:

* It's of type `dir/v1`, so it's a directory-backed StorageClass, and it's using the `default` filesystem
* We're using the provisioner `weka-axon-eks-cluster.weka-operator-system.weka.io` that comes with the WEKA operator
* `volumeBindingMode` is `WaitForFirstConsumer` means that PVC provisioning is delayed until a pod using the PVC is created
* When the PVC is deleted, so is the persistent volume (`reclaimPolicy: Delete`)

You're welcome to set other parameters (see [WEKA documentation](https://docs.weka.io/appendices/weka-csi-plugin/storage-class-configurations)), but it's important to ensure you're using the correct `provisioner-secret-name` and `provisioner-secret-namespace`.

Create the StorageClass:

```bash
kubectl apply -f storageclass-weka.yaml
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

We'll now use the StorageClass to create a PVC and add it to a test application pod.

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

We're going to be creating this PVC in the `weka-axon-test` namespace, multiple nodes can mount the volume (`ReadWriteMany`), and it's `10Gi` in size.

Apply:

```bash
kubectl apply -f pvc.yaml
```

And check that it was created:

```bash
kubectl get pvc -n weka-axon-test

NAME             STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS                  VOLUMEATTRIBUTESCLASS   AGE
pvc-wekafs-dir   Pending                                      storageclass-wekafs-dir-api   <unset>                 19s
```

The status is **PENDING** as we specified a binding mode of `WaitForFirstConsumer` in the StorageClass definition. It will be created once we deploy an application pod that references the PVC.

## 10. Create Test Pod

Below is an example pod that uses the PVC we created and mounts it onto `/data` in a container, and then writes some data:

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
      image: busybox:1.36
      command:
        - sh
        - -lc
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
kubectl apply -f weka-app.yaml
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

We can also check that this data is persistent on the WEKA filesystem. Below is an example pod that will use the same PVC to read the data written by our application pod:

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
      image: busybox:1.36
      command:
        - sh
        - -lc
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
kubectl apply -f weka-app-reader.yaml
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

## 11. Cleanup

Once you're done, you can remove some or all of the components

```bash
kubectl delete namespace weka-axon-test
kubectl delete storageclass storageclass-wekafs-dir-api
kubectl delete wekaclient -n weka-operator-system --all
kubectl delete wekacluster -n weka-operator-system --all
helm uninstall weka-operator -n weka-operator-system
cd ../../terraform && terraform destroy
```
