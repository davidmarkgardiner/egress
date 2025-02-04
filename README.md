# AKS Static Egress Gateway Demo

This repository demonstrates how to set up static egress IPs for AKS workloads using the open-source `kube-egress-gateway` project. This configuration allows pods to access the internet via default Azure networking or use static private egress IP(s) when accessing specific private RFC-1918 destinations.

## Prerequisites

- Azure CLI installed and configured
- kubectl installed
- Helm 3.x installed
- An active Azure subscription

## Architecture Overview

The setup consists of:
- An AKS cluster with a dedicated VMSS node pool for the egress gateway
- A target workload (nginx pod) in a separate namespace
- Static egress gateway configuration for predictable source IPs when accessing workloads in other namespaces

This demo shows how to:
- Configure static egress IPs for specific pod-to-pod communications
- Control egress traffic patterns within the cluster
- Maintain predictable source IPs for internal communication

## Quick Start

1. Clone this repository:
```bash
git clone <repository-url>
cd <repository-name>
```

2. Run the setup script:
```bash
./setup.sh
```

Or follow the manual setup steps below.

## Manual Setup Steps

### 1. Environment Configuration

```bash
# Configure these variables to suit your environment:
LOCATION=australiasoutheast
CLUSTER=egress-demo
RG_NAME=egress-demo
EGRESS_NODE_POOL=egressgw
DEFAULT_SUBNET_NAME=default
EGRESS_SUBNET_NAME=egress
VNET_NAME=$CLUSTER-vnet

# Network configuration
VNET_PREFIX=10.224.0.0/16           # Main VNET
DEFAULT_SUBNET_PREFIX=10.224.0.0/27  # Default subnet (32 IPs)
EGRESS_SUBNET_PREFIX=10.224.1.0/28   # Egress subnet (16 IPs)
POD_CIDR=192.168.0.0/16             # Pod CIDR for overlay networking
```

### 2. Create AKS Cluster and Infrastructure

```bash
# Create resource group
az group create -n $RG_NAME -l $LOCATION

# Create VNET and default subnet
az network vnet create -g $RG_NAME -n $VNET_NAME \
    --address-prefixes $VNET_PREFIX \
    --subnet-name $DEFAULT_SUBNET_NAME \
    --subnet-prefixes $DEFAULT_SUBNET_PREFIX

# Get subnet ID
DEFAULT_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME \
    --vnet-name $VNET_NAME --name $DEFAULT_SUBNET_NAME --query id -o tsv)

# Create egress subnet
az network vnet subnet create -g $RG_NAME \
    --vnet-name $VNET_NAME -n $EGRESS_SUBNET_NAME \
    --address-prefixes $EGRESS_SUBNET_PREFIX

# Get egress subnet ID
EGRESS_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME \
    --vnet-name $VNET_NAME -n $EGRESS_SUBNET_NAME --query id -o tsv)

# Create AKS cluster
az aks create \
    -g $RG_NAME \
    -n $CLUSTER \
    --node-count 2 \
    --enable-managed-identity \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --outbound-type loadBalancer \
    --pod-cidr $POD_CIDR \
    --vnet-subnet-id $DEFAULT_SUBNET_ID \
    --generate-ssh-keys

# Add egress gateway node pool
az aks nodepool add \
    -g $RG_NAME \
    --cluster-name $CLUSTER \
    -n $EGRESS_NODE_POOL \
    --node-count 2 \
    --node-taints "kubeegressgateway.azure.com/mode=true:NoSchedule" \
    --labels "kubeegressgateway.azure.com/mode=true" \
    --os-type Linux \
    --vnet-subnet-id $EGRESS_SUBNET_ID
```

### 3. Configure Identity

You can use either a User-Assigned Managed Identity (UAMI) or a Service Principal (SPN) for authentication. Choose one of the following options:

#### Option A: User-Assigned Managed Identity (Recommended)

```bash
# Create managed identity
EGRESS_IDENTITY_NAME="staticegress-msi"
az identity create -g $RG_NAME -n $EGRESS_IDENTITY_NAME

# Get identity details
IDENTITY_CLIENT_ID=$(az identity show -g $RG_NAME -n $EGRESS_IDENTITY_NAME -o tsv --query "clientId")
IDENTITY_RESOURCE_ID=$(az identity show -g $RG_NAME -n $EGRESS_IDENTITY_NAME -o tsv --query "id")
```

#### Option B: Service Principal

You can either create a new Service Principal or use an existing one:

```bash
# Option B.1: Create new service principal
SP_NAME="staticegress-sp"
SP_CREDENTIAL=$(az ad sp create-for-rbac --name $SP_NAME --skip-assignment)
IDENTITY_CLIENT_ID=$(echo $SP_CREDENTIAL | jq -r .appId)
IDENTITY_CLIENT_SECRET=$(echo $SP_CREDENTIAL | jq -r .password)
TENANT_ID=$(echo $SP_CREDENTIAL | jq -r .tenant)
```

```bash
# Option B.2: Use existing service principal
SP_NAME="your-existing-sp-name"
# Get client ID (application ID) of the existing service principal
IDENTITY_CLIENT_ID=$(az ad sp list --display-name $SP_NAME --query '[0].appId' -o tsv)
# Reset credentials if needed
SP_CREDENTIAL=$(az ad sp credential reset --id $IDENTITY_CLIENT_ID)
IDENTITY_CLIENT_SECRET=$(echo $SP_CREDENTIAL | jq -r .password)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

#### Understanding Role Assignments

The following role assignments are required for the egress gateway controller to function properly:

1. **Network Contributor** on cluster resource group (`$RG_ID`):
   - Allows managing and configuring network settings in the AKS VNET
   - Enables creation and management of load balancers
   - Permits configuration of IP configurations and network interfaces
   - Allows management of subnet configurations

2. **Network Contributor** on node resource group (`$NODE_RG_ID`):
   - Required for managing networking resources in the AKS node resource group
   - Enables configuration of internal load balancers
   - Permits management of network settings for egress gateway nodes

3. **Virtual Machine Contributor** on egress VMSS (`$EGRESS_VMSS_ID`):
   - Allows management of the Virtual Machine Scale Set running egress gateway nodes
   - Enables updates to network configurations on VMSS instances
   - Permits management of IP configurations on VMSS network interfaces

These permissions follow the principle of least privilege by scoping the permissions only to the specific resources needed for the egress gateway functionality.

```bash
# Get subscription and resource group details
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
NODE_RESOURCE_GROUP="$(az aks show -n $CLUSTER -g $RG_NAME --query nodeResourceGroup -o tsv)"
EGRESS_VMSS_NAME=$(az vmss list -g $NODE_RESOURCE_GROUP --query [].name -o tsv | grep $EGRESS_NODE_POOL)

# Assign required roles (same for both UAMI and SPN)
RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"
NODE_RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_RESOURCE_GROUP"
EGRESS_VMSS_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachineScaleSets/$EGRESS_VMSS_NAME"

az role assignment create --role "Network Contributor" --assignee $IDENTITY_CLIENT_ID --scope $RG_ID
az role assignment create --role "Network Contributor" --assignee $IDENTITY_CLIENT_ID --scope $NODE_RG_ID
az role assignment create --role "Virtual Machine Contributor" --assignee $IDENTITY_CLIENT_ID --scope $EGRESS_VMSS_ID
```

### 4. Create Target Workload

Instead of creating a separate container instance, we'll create a simple nginx pod in a different namespace to simulate the target workload. This approach is simpler and demonstrates the same egress functionality.

```bash
# Create target namespace
kubectl create namespace target-workload

# Deploy nginx pod as target workload
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: target-app
  namespace: target-workload
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: target-app-svc
  namespace: target-workload
spec:
  selector:
    app: target-app
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

# Get the pod IP to use as target
TARGET_IP=$(kubectl get pod target-app -n target-workload -o jsonpath='{.status.podIP}')
```

### 5. Install Egress Gateway Controller

```bash
# Create azure_config.yaml based on your identity choice

# For User-Assigned Managed Identity:
cat << EOF > azure_config.yaml
config:
  azureCloudConfig:
    cloud: "AzurePublicCloud"
    tenantId: "$(az account show --query tenantId -o tsv)"
    subscriptionId: "$SUBSCRIPTION_ID"
    useManagedIdentityExtension: true
    userAssignedIdentityID: "$IDENTITY_CLIENT_ID"
    userAgent: "kube-egress-gateway-controller"
    resourceGroup: "$NODE_RESOURCE_GROUP"
    location: "$LOCATION"
    gatewayLoadBalancerName: "kubeegressgateway-ilb"
    loadBalancerResourceGroup: "$NODE_RESOURCE_GROUP"
    vnetName: "$VNET_NAME"
    vnetResourceGroup: "$RG_NAME"
    subnetName: "$EGRESS_SUBNET_NAME"
EOF

# For Service Principal:
cat << EOF > azure_config.yaml
config:
  azureCloudConfig:
    cloud: "AzurePublicCloud"
    tenantId: "$TENANT_ID"
    subscriptionId: "$SUBSCRIPTION_ID"
    aadClientId: "$IDENTITY_CLIENT_ID"
    aadClientSecret: "$IDENTITY_CLIENT_SECRET"
    userAgent: "kube-egress-gateway-controller"
    resourceGroup: "$NODE_RESOURCE_GROUP"
    location: "$LOCATION"
    gatewayLoadBalancerName: "kubeegressgateway-ilb"
    loadBalancerResourceGroup: "$NODE_RESOURCE_GROUP"
    vnetName: "$VNET_NAME"
    vnetResourceGroup: "$RG_NAME"
    subnetName: "$EGRESS_SUBNET_NAME"
EOF

# Install Helm chart
helm install \
  kube-egress-gateway ./kube-egress-gateway/helm/kube-egress-gateway \
  --namespace kube-egress-gateway-system \
  --create-namespace \
  --set common.imageRepository=mcr.microsoft.com/aks \
  --set common.imageTag=v0.0.8 \
  -f ./azure_config.yaml
```

### 6. Configure Static Gateway

```bash
# Create static gateway configuration
kubectl apply -f - <<EOF
apiVersion: egressgateway.kubernetes.azure.com/v1alpha1
kind: StaticGatewayConfiguration
metadata:
  name: myegressgateway
  namespace: demo
spec:
  defaultRoute: staticEgressGateway
  routeCidrs:
  - $POD_CIDR  # Pod CIDR to capture traffic to other pods
  excludeCidrs:
  - 168.63.129.16/32  # Azure DNS
  - 10.224.0.0/16     # AKS VNET
  gatewayVmssProfile:
    vmssName: $EGRESS_VMSS_NAME
    vmssResourceGroup: $NODE_RESOURCE_GROUP
  provisionPublicIps: false
EOF
```

This configuration ensures that:
- Traffic to pods in other namespaces goes through the egress gateway
- Azure DNS (168.63.129.16/32) is excluded to maintain cluster functionality
- AKS VNET traffic is excluded to maintain direct pod-to-pod communication within the same VNET

### 7. Deploy and Test

```bash
# Create namespace
kubectl create namespace demo

# Deploy test pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: app2
  namespace: demo
  annotations:
    egressgateway.kubernetes.azure.com/gateway-name: myegressgateway
  labels:
    app: app2
spec:
  containers:
  - name: app
    image: curlimages/curl
    command: ["sleep", "infinity"]
EOF

# Test connectivity
kubectl exec -n demo app2 -- curl -v http://$TARGET_IP
```

## Cleanup

To remove all resources:
```bash
az group delete -n $RG_NAME --yes --no-wait
```

## Troubleshooting

1. Check egress gateway controller logs:
```bash
kubectl logs -n kube-egress-gateway-system -l app=kube-egress-gateway-controller-manager
```

2. Verify static gateway configuration:
```bash
kubectl describe staticgatewayconfiguration myegressgateway -n demo
```

3. Check pod routing:
```bash
kubectl exec -n demo app2 -- ip route
```

## References

- [kube-egress-gateway GitHub Repository](https://github.com/Azure/kube-egress-gateway)
- [Azure Container Instances Documentation](https://docs.microsoft.com/en-us/azure/container-instances/)
- [AKS Documentation](https://docs.microsoft.com/en-us/azure/aks/) 