# Configuring Static Egress Gateway on Existing AKS Cluster (PowerShell)

This guide explains how to configure static egress gateway on an existing AKS cluster using PowerShell. This is different from setting up a new cluster as we need to work with your existing networking configuration.

## Prerequisites

- Existing AKS cluster
- Azure PowerShell modules installed (`Az` module)
- kubectl installed and configured for your cluster
- Helm 3.x installed
- Contributor access to:
  - The AKS cluster
  - The VNET where AKS is deployed
  - The resource group containing the AKS cluster

## Steps

### 1. Gather Existing Configuration

First, gather information about your existing cluster:

```powershell
# Set variables for your environment
$ClusterName = "your-cluster-name"
$ClusterResourceGroup = "your-cluster-resource-group"

# Connect to Azure if not already connected
Connect-AzAccount

# Get cluster details
$AksCluster = Get-AzAksCluster -ResourceGroupName $ClusterResourceGroup -Name $ClusterName
$NodeResourceGroup = $AksCluster.NodeResourceGroup
$Location = $AksCluster.Location
$VnetName = $AksCluster.NetworkProfile.VnetName

# Get VNET resource group (if different from cluster resource group)
$VnetResourceGroup = if ($AksCluster.NetworkProfile.VnetResourceGroup) {
    $AksCluster.NetworkProfile.VnetResourceGroup
} else {
    $ClusterResourceGroup
}
```

### 2. Create Egress Subnet

Create a new subnet for the egress gateway nodes:

```powershell
# Define egress subnet details
$EgressSubnetName = "egress-subnet"
$EgressSubnetPrefix = "10.x.x.x/24"  # Choose an available CIDR range in your VNET

# Create the subnet
$VirtualNetwork = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup
Add-AzVirtualNetworkSubnetConfig -Name $EgressSubnetName `
    -VirtualNetwork $VirtualNetwork `
    -AddressPrefix $EgressSubnetPrefix
$VirtualNetwork | Set-AzVirtualNetwork

# Get subnet ID
$EgressSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $VirtualNetwork -Name $EgressSubnetName
$EgressSubnetId = $EgressSubnet.Id
```

### 3. Add Egress Gateway Node Pool

```powershell
# Add the egress gateway node pool
$EgressNodePool = "egressgw"

New-AzAksNodePool -ResourceGroupName $ClusterResourceGroup `
    -ClusterName $ClusterName `
    -Name $EgressNodePool `
    -NodeCount 2 `
    -VnetSubnetID $EgressSubnetId `
    -NodeTaints "kubeegressgateway.azure.com/mode=true:NoSchedule" `
    -Labels @{"kubeegressgateway.azure.com/mode"="true"} `
    -OsType Linux
```

### 4. Create and Configure Managed Identity

```powershell
# Create managed identity
$EgressIdentityName = "staticegress-msi"
$Identity = New-AzUserAssignedIdentity -ResourceGroupName $ClusterResourceGroup `
    -Name $EgressIdentityName -Location $Location

# Get identity details
$IdentityClientId = $Identity.ClientId
$IdentityResourceId = $Identity.Id

# Get subscription ID
$SubscriptionId = (Get-AzContext).Subscription.Id

# Get VMSS name
$EgressVmss = Get-AzVmss -ResourceGroupName $NodeResourceGroup | 
    Where-Object { $_.Name -like "*$EgressNodePool*" }
$EgressVmssName = $EgressVmss.Name

# Set up role assignments
$RgId = "/subscriptions/$SubscriptionId/resourceGroups/$ClusterResourceGroup"
$NodeRgId = "/subscriptions/$SubscriptionId/resourceGroups/$NodeResourceGroup"
$EgressVmssId = $EgressVmss.Id

New-AzRoleAssignment -ObjectId $Identity.PrincipalId `
    -RoleDefinitionName "Network Contributor" `
    -Scope $RgId

New-AzRoleAssignment -ObjectId $Identity.PrincipalId `
    -RoleDefinitionName "Network Contributor" `
    -Scope $NodeRgId

New-AzRoleAssignment -ObjectId $Identity.PrincipalId `
    -RoleDefinitionName "Virtual Machine Contributor" `
    -Scope $EgressVmssId
```

### 5. Install Egress Gateway Controller

```powershell
# Create azure_config.yaml
$TenantId = (Get-AzContext).Tenant.Id
$AzureConfig = @"
config:
  azureCloudConfig:
    cloud: "AzurePublicCloud"
    tenantId: "$TenantId"
    subscriptionId: "$SubscriptionId"
    useManagedIdentityExtension: true
    userAssignedIdentityID: "$IdentityClientId"
    userAgent: "kube-egress-gateway-controller"
    resourceGroup: "$NodeResourceGroup"
    location: "$Location"
    gatewayLoadBalancerName: "kubeegressgateway-ilb"
    loadBalancerResourceGroup: "$NodeResourceGroup"
    vnetName: "$VnetName"
    vnetResourceGroup: "$VnetResourceGroup"
    subnetName: "$EgressSubnetName"
"@

Set-Content -Path azure_config.yaml -Value $AzureConfig

# Clone the repository if not already done
if (-not (Test-Path "kube-egress-gateway")) {
    git clone https://github.com/Azure/kube-egress-gateway.git
}

# Install using Helm
helm install `
    kube-egress-gateway ./kube-egress-gateway/helm/kube-egress-gateway `
    --namespace kube-egress-gateway-system `
    --create-namespace `
    --set common.imageRepository=mcr.microsoft.com/aks `
    --set common.imageTag=v0.0.8 `
    -f ./azure_config.yaml
```

### 6. Configure Static Gateway

```powershell
# Create namespace
kubectl create namespace demo

# Get existing VNET CIDR
$ExistingVnetCidr = $VirtualNetwork.AddressSpace.AddressPrefixes[0]

# Get Pod CIDR if using overlay networking
$PodCidr = "192.168.0.0/16"  # Update this with your actual Pod CIDR

# Create static gateway configuration
$GatewayConfig = @"
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
  - $ExistingVnetCidr
  - $PodCidr
  gatewayVmssProfile:
    vmssName: $EgressVmssName
    vmssResourceGroup: $NodeResourceGroup
  provisionPublicIps: false
"@

$GatewayConfig | kubectl apply -f -
```

### 7. Test Configuration

Deploy a test pod:

```powershell
$TestPod = @"
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
"@

$TestPod | kubectl apply -f -

# Test connectivity to your target network
kubectl exec -n demo test-pod -- curl -v http://your-target-ip
```

## Troubleshooting

1. Verify node pool creation:
```powershell
kubectl get nodes -l kubeegressgateway.azure.com/mode=true
```

2. Check egress gateway controller logs:
```powershell
kubectl logs -n kube-egress-gateway-system -l app=kube-egress-gateway-controller-manager
```

3. Verify static gateway configuration:
```powershell
kubectl describe staticgatewayconfiguration myegressgateway -n demo
```

4. Check pod routing:
```powershell
kubectl exec -n demo test-pod -- ip route
```

5. Verify VMSS configuration:
```powershell
Get-AzVmss -ResourceGroupName $NodeResourceGroup -VMScaleSetName $EgressVmssName
```

## Common Issues

1. **Subnet Conflicts**: Ensure the egress subnet CIDR doesn't overlap with existing subnets.

2. **RBAC Issues**: Verify the managed identity has all required permissions:
```powershell
Get-AzRoleAssignment -ObjectId $Identity.PrincipalId
```

3. **Network Plugin Compatibility**: If using kubenet, additional route table configuration may be needed.

4. **Pod Network Connectivity**: Ensure the `excludeCidrs` list correctly includes your cluster's VNET and pod CIDRs.

## Cleanup

To remove the egress gateway configuration:

```powershell
# Delete the gateway configuration
kubectl delete staticgatewayconfiguration myegressgateway -n demo

# Uninstall the helm chart
helm uninstall kube-egress-gateway -n kube-egress-gateway-system

# Delete the node pool (optional)
Remove-AzAksNodePool -ResourceGroupName $ClusterResourceGroup `
    -ClusterName $ClusterName `
    -Name $EgressNodePool

# Delete the managed identity
Remove-AzUserAssignedIdentity -ResourceGroupName $ClusterResourceGroup `
    -Name $EgressIdentityName

# Delete the egress subnet (optional)
$VirtualNetwork = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup
Remove-AzVirtualNetworkSubnetConfig -Name $EgressSubnetName -VirtualNetwork $VirtualNetwork
$VirtualNetwork | Set-AzVirtualNetwork
``` 