 # AKS Static Egress Control Guide

## Overview

This guide demonstrates how to implement predictable outbound IP addresses for specific workloads in Azure Kubernetes Service (AKS) using `kube-egress-gateway`. This solution is particularly useful when you need to control and manage outbound traffic from your AKS cluster to specific destinations.

## What Problem Does This Solve?

### Traditional AKS Egress Challenge
- All pods use IPs from the entire AKS subnet for outbound traffic
- Need to whitelist the entire AKS subnet in firewalls (e.g., 10.224.0.0/27)
- No granular control over which pods use which IPs

### Solution Benefits
- Use a small, dedicated subnet for egress traffic (e.g., 10.224.1.0/28)
- Opt-in model: choose which pods use static egress IPs
- Maintain regular AKS networking for other pods
- Predictable source IPs for firewall rules

## How It Works

### 1. Network Architecture

```plaintext
┌─────────────────────────────────────────────┐
│ AKS Cluster                                 │
│  ┌──────────────┐      ┌──────────────┐    │
│  │ Regular Pod  │      │ Static Pod   │    │
│  │ (10.224.0.x)│      │ (10.224.1.x) │    │
│  └──────────────┘      └──────────────┘    │
│         │                     │             │
│  ┌──────────────┐    ┌────────────────┐    │
│  │ Default      │    │ Egress         │    │
│  │ Subnet       │    │ Subnet         │    │
│  │ 10.224.0.0/27│    │ 10.224.1.0/28 │    │
│  └──────────────┘    └────────────────┘    │
└─────────────────────────────────────────────┘
```

### 2. Traffic Flow

#### Regular Pod Traffic:
- Uses default AKS networking
- Source IP from AKS subnet (10.224.0.0/27)
- No special configuration needed

#### Static Egress Pod Traffic:
- Uses dedicated egress subnet (10.224.1.0/28)
- Requires pod annotation to opt-in
- Predictable source IPs for firewall rules

## Implementation Guide

### 1. Pod Configuration Examples

#### Regular Pod (Default Networking)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: regular-app
  namespace: demo
spec:
  template:
    metadata:
      labels:
        app: regular-app
    spec:
      containers:
      - name: app
        image: nginx:latest
```

#### Pod with Static Egress
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: static-egress-app
  namespace: demo
spec:
  template:
    metadata:
      labels:
        app: static-egress-app
      annotations:
        kubernetes.azure.com/static-gateway-configuration: myegressgateway  # Enable static egress
    spec:
      containers:
      - name: app
        image: nginx:latest
```

### 2. Important Concepts

#### Namespace Scope
- Each StaticGatewayConfiguration is namespace-specific
- Only pods in the same namespace can use it
- Different namespaces can have different egress configurations

#### IP Assignment
- NOT automatic per namespace
- Pods must opt-in using annotations
- Predictable IP range from egress subnet

#### Firewall Rules
Before:
```
Allow 10.224.0.0/27 (entire AKS subnet)
```

After:
```
Allow 10.224.1.0/28 (small egress subnet)
```

## Common Use Cases

1. **On-Premises Access**
   - Predictable source IPs for on-prem firewall rules
   - Smaller IP ranges to whitelist

2. **Third-Party Service Integration**
   - Static IPs for external service whitelisting
   - Better security compliance

3. **Multi-tenant Clusters**
   - Different egress IPs per namespace/tenant
   - Isolated traffic patterns

4. **Compliance Requirements**
   - Trackable outbound traffic sources
   - Auditable egress patterns

## Best Practices

1. **Subnet Planning**
   - Use small subnet for egress (e.g., /28 = 16 IPs)
   - Reserve enough IPs for scalability

2. **Pod Configuration**
   - Only enable static egress where needed
   - Document which pods use static egress

3. **Monitoring**
   - Track egress IP usage
   - Monitor gateway node health

4. **Security**
   - Regularly audit egress configurations
   - Review and update firewall rules

## Quick Reference

### Check Pod's Egress IP
```bash
# For regular pod
kubectl exec -n demo regular-app -- curl ifconfig.me

# For static egress pod
kubectl exec -n demo static-egress-app -- curl ifconfig.me
```

### Verify Configuration
```bash
# Check gateway status
kubectl describe StaticGatewayConfiguration myegressgateway -n demo

# View gateway logs
kubectl logs -n kube-egress-gateway-system -l app=kube-egress-gateway-controller-manager
```

## References

- [kube-egress-gateway Documentation](https://github.com/Azure/kube-egress-gateway)
- [AKS Networking Concepts](https://docs.microsoft.com/en-us/azure/aks/concepts-network)

---


Let me help explain how the static IP allocation works in this egress gateway solution:

1. The static IP allocation is not automatically assigned per namespace. Instead, it's based on the `StaticGatewayConfiguration` and how you configure your pods to use it.

Let me search for the relevant configuration to show you how this works:

Search files...


Let me explain how the static IP allocation works:

1. The `StaticGatewayConfiguration` is namespace-scoped, which means it can only be used by pods in the same namespace where it's created.

2. Pods need to explicitly opt-in to use the static egress gateway by adding an annotation:
```yaml
annotations:
  egressgateway.kubernetes.azure.com/gateway-name: myegressgateway
```

3. For your specific questions:
   - Each namespace does NOT automatically get a static IP for outbound traffic
   - For app1 connecting to app2:
     - If app1 doesn't have the egress gateway annotation, it will use the default AKS networking (IP from the AKS subnet)
     - If app1 has the egress gateway annotation, it will use an IP from the egress subnet
     - Same applies for app2 - it needs to explicitly opt-in to use the static egress IP

4. The static IPs come from the egress subnet that you configured (`EGRESS_SUBNET_PREFIX`). In the example setup, this is `10.224.1.0/28` which provides 16 IPs.

Let me show you a practical example by looking at the test configuration:

Read file: static-egress-private-ip/app-staticegress.yaml

Read file: static-egress-private-ip/app-nostaticegress.yaml


As you can see from these examples:

1. `app1` (in app-nostaticegress.yaml) has no special annotation - it will use regular AKS networking with IPs from the default subnet
2. `app2` (in app-staticegress.yaml) has the annotation `kubernetes.azure.com/static-gateway-configuration: myegressgateway` - it will use IPs from the egress subnet

So to answer your firewall question:
- If you need to open firewall rules for app1's outbound traffic, you'd need to allow the entire AKS subnet (10.224.0.0/27 in the example)
- If you need to open firewall rules for app2's outbound traffic, you only need to allow the egress subnet IPs (10.224.1.0/28 in the example)

This gives you much more granular control over egress traffic, as you can:
1. Choose which pods use static egress IPs by adding/removing the annotation
2. Use a much smaller IP range in your firewall rules for pods that need static egress
3. Keep regular pods using the default AKS networking

The static egress feature is opt-in at the pod level, not automatic at the namespace level. This gives you fine-grained control over which workloads use static egress IPs.
