# PoC On Header Transformation

PoC to demonstrate the header based transformation. In this PoC, Gloo Edge will compute whether the request should be accepted or rejected based on a given user-agent header.

## Prerequisites

1. Create kind cluster

    ```
    cat <<EOF | kind create cluster --name ge-header-trans --image kindest/node:v1.24.0@sha256:0866296e693efe1fed79d5e6c7af8df71fc73ae45e3679af05342239cdc5bc8e --config=-
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
    - role: control-plane
        extraPortMappings:
            - containerPort: 31080
            hostPort: 31080
            protocol: TCP
            - containerPort: 31443
            hostPort: 31443
            protocol: TCP
    EOF
    ```

## Setup Gloo Edge

```
helm install glooe glooe/gloo-ee -n gloo-system --version 1.11.19 --create-namespace --set-string license_key=$GLOO_EDGE_LICENSE_KEY -f gloo-edge-helm-values.yaml
```

## Deploy application and test

1. Inject application resources

    ```
    kubectl create ns apps-configuration

    kubectl apply -f apps/
    kubectl apply -f configuration/
    ```

2. Test the transformation

    ```
    curl -iv -A "Mercari_r/361 (iPhone OS 10.1.3; ja; iPhone6,1)" http://localhost:31080/get
    ```