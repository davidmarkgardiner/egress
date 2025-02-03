# Configuring Static Egress Gateway on Existing AKS Cluster

This guide explains how to configure static egress gateway on an existing AKS cluster. This is different from setting up a new cluster as we need to work with your existing networking configuration.

## Prerequisites

- Existing AKS cluster
- Azure CLI installed and configured
- kubectl installed and configured for your cluster
- Helm 3.x installed
- Contributor access to:
  - The AKS cluster
  - The VNET where AKS is deployed
  - The resource group containing the AKS cluster

## Steps

### 1. Gather Existing Configuration

First, gather information about your existing cluster:

```bash
# Set variables for your environment
CLUSTER_NAME="your-cluster-name"
CLUSTER_RG="your-cluster-resource-group"

# Get cluster details
VNET_NAME=$(az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query networkProfile.networkPlugin -o tsv)
NODE_RG=$(az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query nodeResourceGroup -o tsv)
VNET_RG=$(az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query networkProfile.vnetResourceGroup -o tsv)
LOCATION=$(az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query location -o tsv)

# If vnetResourceGroup is empty, use cluster resource group
if [ -z "$VNET_RG" ]; then
    VNET_RG=$CLUSTER_RG
fi

# Get VNET details
VNET_NAME=$(az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query networkProfile.vnetName -o tsv)
```

### 2. Create Egress Subnet

Create a new subnet for the egress gateway nodes:

```bash
# Define egress subnet details
EGRESS_SUBNET_NAME="egress-subnet"
EGRESS_SUBNET_PREFIX="10.x.x.x/24"  # Choose an available CIDR range in your VNET

# Create the subnet
az network vnet subnet create \
    --resource-group $VNET_RG \
    --vnet-name $VNET_NAME \
    --name $EGRESS_SUBNET_NAME \
    --address-prefix $EGRESS_SUBNET_PREFIX

# Get subnet ID
EGRESS_SUBNET_ID=$(az network vnet subnet show \
    --resource-group $VNET_RG \
    --vnet-name $VNET_NAME \
    --name $EGRESS_SUBNET_NAME \
    --query id -o tsv)
```

### 3. Add Egress Gateway Node Pool

```bash
# Add the egress gateway node pool
EGRESS_NODE_POOL="egressgw"

az aks nodepool add \
    --resource-group $CLUSTER_RG \
    --cluster-name $CLUSTER_NAME \
    --name $EGRESS_NODE_POOL \
    --node-count 2 \
    --node-taints "kubeegressgateway.azure.com/mode=true:NoSchedule" \
    --labels "kubeegressgateway.azure.com/mode=true" \
    --os-type Linux \
    --vnet-subnet-id $EGRESS_SUBNET_ID
```

### 4. Create and Configure Managed Identity

```bash
# Create managed identity
EGRESS_IDENTITY_NAME="staticegress-msi"
az identity create -g $CLUSTER_RG -n $EGRESS_IDENTITY_NAME

# Get identity details
IDENTITY_CLIENT_ID=$(az identity show -g $CLUSTER_RG -n $EGRESS_IDENTITY_NAME -o tsv --query "clientId")
IDENTITY_RESOURCE_ID=$(az identity show -g $CLUSTER_RG -n $EGRESS_IDENTITY_NAME -o tsv --query "id")

# Get subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Get VMSS name
EGRESS_VMSS_NAME=$(az vmss list -g $NODE_RG --query "[?contains(name, '$EGRESS_NODE_POOL')].name" -o tsv)

# Set up role assignments
RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$CLUSTER_RG"
NODE_RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_RG"
EGRESS_VMSS_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_RG/providers/Microsoft.Compute/virtualMachineScaleSets/$EGRESS_VMSS_NAME"

az role assignment create --role "Network Contributor" --assignee $IDENTITY_CLIENT_ID --scope $RG_ID
az role assignment create --role "Network Contributor" --assignee $IDENTITY_CLIENT_ID --scope $NODE_RG_ID
az role assignment create --role "Virtual Machine Contributor" --assignee $IDENTITY_CLIENT_ID --scope $EGRESS_VMSS_ID
```

### 5. Install Egress Gateway Controller

```bash
# Create azure_config.yaml
cat << EOF > azure_config.yaml
config:
  azureCloudConfig:
    cloud: "AzurePublicCloud"
    tenantId: "$(az account show --query tenantId -o tsv)"
    subscriptionId: "$SUBSCRIPTION_ID"
    useManagedIdentityExtension: true
    userAssignedIdentityID: "$IDENTITY_CLIENT_ID"
    userAgent: "kube-egress-gateway-controller"
    resourceGroup: "$NODE_RG"
    location: "$LOCATION"
    gatewayLoadBalancerName: "kubeegressgateway-ilb"
    loadBalancerResourceGroup: "$NODE_RG"
    vnetName: "$VNET_NAME"
    vnetResourceGroup: "$VNET_RG"
    subnetName: "$EGRESS_SUBNET_NAME"
EOF

# Clone the repository if not already done
if [ ! -d "kube-egress-gateway" ]; then
    git clone https://github.com/Azure/kube-egress-gateway.git
fi

# Install using Helm
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
# Create namespace
kubectl create namespace demo

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
  - 10.0.0.0/8  # Adjust this to match your target network CIDR
  excludeCidrs:
  - 168.63.129.16/32
  - $EXISTING_VNET_CIDR  # Your existing VNET CIDR
  - $POD_CIDR           # Your pod CIDR if using overlay networking
  gatewayVmssProfile:
    vmssName: $EGRESS_VMSS_NAME
    vmssResourceGroup: $NODE_RG
  provisionPublicIps: false
EOF
```

### 7. Test Configuration

Deploy a test pod:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: demo
  annotations:
    egressgateway.kubernetes.azure.com/gateway-name: myegressgateway
spec:
  containers:
  - name: curl
    image: curlimages/curl
    command: ["sleep", "infinity"]
EOF
```

Test connectivity to your target network:
```bash
kubectl exec -n demo test-pod -- curl -v http://your-target-ip
```

## Troubleshooting

1. Verify node pool creation:
```bash
kubectl get nodes -l kubeegressgateway.azure.com/mode=true
```

2. Check egress gateway controller logs:
```bash
kubectl logs -n kube-egress-gateway-system -l app=kube-egress-gateway-controller-manager
```

3. Verify static gateway configuration:
```bash
kubectl describe staticgatewayconfiguration myegressgateway -n demo
```

4. Check pod routing:
```bash
kubectl exec -n demo test-pod -- ip route
```

5. Verify VMSS configuration:
```bash
az vmss show -g $NODE_RG -n $EGRESS_VMSS_NAME
```

## Common Issues

1. **Subnet Conflicts**: Ensure the egress subnet CIDR doesn't overlap with existing subnets.

2. **RBAC Issues**: Verify the managed identity has all required permissions.

3. **Network Plugin Compatibility**: If using kubenet, additional route table configuration may be needed.

4. **Pod Network Connectivity**: Ensure the `excludeCidrs` list correctly includes your cluster's VNET and pod CIDRs.

## Cleanup

To remove the egress gateway configuration:

```bash
# Delete the gateway configuration
kubectl delete staticgatewayconfiguration myegressgateway -n demo

# Uninstall the helm chart
helm uninstall kube-egress-gateway -n kube-egress-gateway-system

# Delete the node pool (optional)
az aks nodepool delete \
    --resource-group $CLUSTER_RG \
    --cluster-name $CLUSTER_NAME \
    --name $EGRESS_NODE_POOL

# Delete the managed identity
az identity delete -g $CLUSTER_RG -n $EGRESS_IDENTITY_NAME

# Delete the egress subnet (optional)
az network vnet subnet delete \
    --resource-group $VNET_RG \
    --vnet-name $VNET_NAME \
    --name $EGRESS_SUBNET_NAME
``` 