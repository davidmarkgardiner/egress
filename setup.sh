#!/bin/bash

set -e

# Print commands before executing
set -x

# Function to check command status
check_status() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Function to wait for resource creation
wait_for_resource() {
    echo "Waiting for $1..."
    sleep $2
}

# Validate prerequisites
command -v az >/dev/null 2>&1 || { echo "Azure CLI is required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Helm is required but not installed. Aborting." >&2; exit 1; }

# Configuration
LOCATION=uksouth
CLUSTER=egress-demo
RG_NAME=egress-demo
EGRESS_NODE_POOL=egressgw
DEFAULT_SUBNET_NAME=default
EGRESS_SUBNET_NAME=egress
VNET_NAME=$CLUSTER-vnet

# Network configuration
VNET_PREFIX=10.224.0.0/16
DEFAULT_SUBNET_PREFIX=10.224.0.0/27
EGRESS_SUBNET_PREFIX=10.224.1.0/28
POD_CIDR=192.168.0.0/16

echo "Creating resource group..."
az group create -n $RG_NAME -l $LOCATION
check_status "Failed to create resource group"

echo "Creating VNET and default subnet..."
az network vnet create -g $RG_NAME -n $VNET_NAME \
    --address-prefixes $VNET_PREFIX \
    --subnet-name $DEFAULT_SUBNET_NAME \
    --subnet-prefixes $DEFAULT_SUBNET_PREFIX
check_status "Failed to create VNET"

echo "Getting default subnet ID..."
DEFAULT_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME \
    --vnet-name $VNET_NAME --name $DEFAULT_SUBNET_NAME --query id -o tsv)
check_status "Failed to get default subnet ID"

echo "Creating egress subnet..."
az network vnet subnet create -g $RG_NAME \
    --vnet-name $VNET_NAME -n $EGRESS_SUBNET_NAME \
    --address-prefixes $EGRESS_SUBNET_PREFIX
check_status "Failed to create egress subnet"

echo "Getting egress subnet ID..."
EGRESS_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME \
    --vnet-name $VNET_NAME -n $EGRESS_SUBNET_NAME --query id -o tsv)
check_status "Failed to get egress subnet ID"

echo "Creating AKS cluster..."
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
check_status "Failed to create AKS cluster"

wait_for_resource "AKS cluster" 60

echo "Adding egress gateway node pool..."
az aks nodepool add \
    -g $RG_NAME \
    --cluster-name $CLUSTER \
    -n $EGRESS_NODE_POOL \
    --node-count 2 \
    --node-taints "kubeegressgateway.azure.com/mode=true:NoSchedule" \
    --labels "kubeegressgateway.azure.com/mode=true" \
    --os-type Linux \
    --vnet-subnet-id $EGRESS_SUBNET_ID
check_status "Failed to add egress gateway node pool"

wait_for_resource "node pool" 60

echo "Creating managed identity..."
EGRESS_IDENTITY_NAME="staticegress-msi"
az identity create -g $RG_NAME -n $EGRESS_IDENTITY_NAME
check_status "Failed to create managed identity"

echo "Getting identity details..."
IDENTITY_CLIENT_ID=$(az identity show -g $RG_NAME -n $EGRESS_IDENTITY_NAME -o tsv --query "clientId")
IDENTITY_RESOURCE_ID=$(az identity show -g $RG_NAME -n $EGRESS_IDENTITY_NAME -o tsv --query "id")
check_status "Failed to get identity details"

echo "Getting subscription and resource group details..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
NODE_RESOURCE_GROUP="$(az aks show -n $CLUSTER -g $RG_NAME --query nodeResourceGroup -o tsv)"
EGRESS_VMSS_NAME=$(az vmss list -g $NODE_RESOURCE_GROUP --query [].name -o tsv | grep $EGRESS_NODE_POOL)
check_status "Failed to get subscription and resource group details"

echo "Setting up role assignments..."
RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"
NODE_RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_RESOURCE_GROUP"
EGRESS_VMSS_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachineScaleSets/$EGRESS_VMSS_NAME"

az role assignment create --role "Network Contributor" --assignee $IDENTITY_CLIENT_ID --scope $RG_ID
az role assignment create --role "Network Contributor" --assignee $IDENTITY_CLIENT_ID --scope $NODE_RG_ID
az role assignment create --role "Virtual Machine Contributor" --assignee $IDENTITY_CLIENT_ID --scope $EGRESS_VMSS_ID
check_status "Failed to create role assignments"

echo "Getting AKS credentials..."
az aks get-credentials -g $RG_NAME -n $CLUSTER --overwrite-existing
check_status "Failed to get AKS credentials"

echo "Creating azure_config.yaml..."
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

echo "Installing egress gateway helm chart..."
if [ ! -d "kube-egress-gateway" ]; then
    git clone https://github.com/Azure/kube-egress-gateway.git
fi

helm install \
  kube-egress-gateway ./kube-egress-gateway/helm/kube-egress-gateway \
  --namespace kube-egress-gateway-system \
  --create-namespace \
  --set common.imageRepository=mcr.microsoft.com/aks \
  --set common.imageTag=v0.0.8 \
  -f ./azure_config.yaml
check_status "Failed to install helm chart"

wait_for_resource "helm installation" 30

echo "Creating demo namespace..."
kubectl create namespace demo
check_status "Failed to create demo namespace"

echo "Creating static gateway configuration..."
kubectl apply -f - <<EOF
apiVersion: egressgateway.kubernetes.azure.com/v1alpha1
kind: StaticGatewayConfiguration
metadata:
  name: myegressgateway
  namespace: demo
spec:
  defaultRoute: staticEgressGateway
  routeCidrs:
  - 10.0.0.0/16
  excludeCidrs:
  - 168.63.129.16/32
  - 10.224.0.0/16
  - 192.168.0.0/16
  gatewayVmssProfile:
    vmssName: $EGRESS_VMSS_NAME
    vmssResourceGroup: $NODE_RESOURCE_GROUP
  provisionPublicIps: false
EOF
check_status "Failed to create static gateway configuration"

echo "Creating test pod..."
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
check_status "Failed to create test pod"

echo "Creating target network..."
TARGET_VNET_NAME="my-target-vnet"
az network vnet create --resource-group $RG_NAME --name $TARGET_VNET_NAME \
    --location $LOCATION --address-prefix 10.0.0.0/16
check_status "Failed to create target network"

echo "Creating container instance..."
az container create \
  --name appcontainer \
  --resource-group $RG_NAME \
  --image mcr.microsoft.com/azuredocs/aci-helloworld \
  --vnet $TARGET_VNET_NAME \
  --vnet-address-prefix 10.0.0.0/16 \
  --subnet apps \
  --subnet-address-prefix 10.0.3.0/24
check_status "Failed to create container instance"

echo "Setting up VNET peering..."
az network vnet peering create --name staticegress-to-target \
    --resource-group $RG_NAME --vnet-name $VNET_NAME \
    --remote-vnet $TARGET_VNET_NAME --allow-vnet-access

az network vnet peering create --name target-to-staticegress \
    --resource-group $RG_NAME --vnet-name $TARGET_VNET_NAME \
    --remote-vnet $VNET_NAME --allow-vnet-access
check_status "Failed to set up VNET peering"

TARGET_IP="$(az container show -n appcontainer -g $RG_NAME --query ipAddress.ip -o tsv)"
echo "Target container IP: $TARGET_IP"

echo "Setup complete! You can now test the connection using:"
echo "kubectl exec -n demo app2 -- curl -v http://$TARGET_IP" 