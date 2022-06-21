# Gloo Mesh 2.0 Demo

Demo implemented for WooliesX
* Includes Vault integration

## Prerequisites

1. Install tools
* Helm v3
* `istioctl` (1.13.5)
* `meshctl` (2.0.8) - `curl -sL https://run.solo.io/meshctl/install | GLOO_MESH_VERSION=v2.0.8 sh -`
* Vault - `brew tap hashicorp/tap && brew install hashicorp/tap/vault`
* cfssl - `brew install cfssl`
* jq

2. Set up environment variables

    ```
    export CLUSTER_OWNER="kasunt"
    export CLUSTER_REGION=ap-southeast-1
    export PROJECT="wooliesx"

    export PARENT_DOMAIN_NAME=kasunt.fe.gl00.net
    export DOMAIN_NAME=${PROJECT}.kasunt.fe.gl00.net

    export EAST_CLUSTER="${PROJECT}-east-cluster"
    export WEST_CLUSTER="${PROJECT}-west-cluster"
    export MGMT_CLUSTER="${PROJECT}-mgmt-cluster"

    export EAST_CONTEXT="${CLUSTER_OWNER}-${EAST_CLUSTER}.${CLUSTER_REGION}.eksctl.io"
    export WEST_CONTEXT="${CLUSTER_OWNER}-${WEST_CLUSTER}.${CLUSTER_REGION}.eksctl.io"
    export MGMT_CONTEXT="${CLUSTER_OWNER}-${MGMT_CLUSTER}.${CLUSTER_REGION}.eksctl.io"
    export EAST_MESH_NAME="east-mesh"
    export WEST_MESH_NAME="west-mesh"
    export MGMT_MESH_NAME="mgmt-mesh"

    export GLOO_MESH_HELM_VERSION=2.0.8
    export GLOO_MESH_VERSION=v2.0.8
    export REPO=us-docker.pkg.dev/gloo-mesh/istio-a9797008feb0
    export ISTIO_VERSION=1.13.5-solo
    export REVISION=1-13-5
    ```

3. Provision the clusters

    ```
    ./cluster-provision/scripts/provision-eks-cluster.sh create -n $EAST_CLUSTER -o $CLUSTER_OWNER -a 3 -v 1.22 -r $CLUSTER_REGION
    ./cluster-provision/scripts/provision-eks-cluster.sh create -n $WEST_CLUSTER -o $CLUSTER_OWNER -a 3 -v 1.22 -r $CLUSTER_REGION
    ./cluster-provision/scripts/provision-eks-cluster.sh create -n $MGMT_CLUSTER -o $CLUSTER_OWNER -a 3 -v 1.22 -r $CLUSTER_REGION
    ```
  
4. Rename contexts due to a bug in GM 2.0

    ```
    kubectl config rename-context kasun@$EAST_CONTEXT $EAST_CONTEXT
    kubectl config rename-context kasun@$WEST_CONTEXT $WEST_CONTEXT
    kubectl config rename-context kasun@$MGMT_CONTEXT $MGMT_CONTEXT
    ```

4. Generate temp dir
    ```
    mkdir -p _output/{gloo-mesh,alb-controller,external-dns,cert-manager}
    ```

## Application Demo

### Deployment

```
./apps/apps-deploy.sh prov
```

### Feature Demo

| Feature   |      Command      |  Comments |
|:----------|:-------------|:------|
| Single cluster traffic routing | `./configuration/single-cluster-traffic/single-cluster-traffic.sh prov` |  |
| Cross cluster traffic routing  | `./configuration/cross-cluster-traffic/cross-cluster-traffic.sh prov`   |  |
| Traffic shifting to reviews v3 | `./configuration/cross-cluster-traffic-shift/cross-cluster-traffic-shift.sh prov` | Shifting traffic to reviews v3 on east cluster |
| Failover policy | `./configuration/failover-policy/failover-policy.sh prov` | Failover to reviews v3 on east cluster when none of the reviews services on west cluster are available |
| Secure with OAuth 2.0 | `./configuration/secure-with-oauth/secure-with-oauth.sh prov` | Secure with Google OIDC |

## Instructions

### Integrations

[Management Cluster](integrations/INTEGRATION_MGMT_CLUSTER.md)

[West Cluster](integrations/INTEGRATION_WEST_CLUSTER.md)

[East Cluster](integrations/INTEGRATION_EAST_CLUSTER.md) - This is optional for now.

#### PKI Integration

### Setting up Istio

[West Cluster](ISTIO_WEST_CLUSTER.md)

[East Cluster](ISTIO_EAST_CLUSTER.md)

### Deploy Gloo Management plane

```
# Update CRDs
helm repo add gloo-mesh-enterprise https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-enterprise 
helm repo update
helm pull gloo-mesh-enterprise/gloo-mesh-enterprise --version $GLOO_MESH_HELM_VERSION --untar
kubectl --context ${MGMT_CONTEXT} apply -f gloo-mesh-enterprise/charts/gloo-mesh-crds/crds
rm -rf gloo-mesh-enterprise

envsubst < gloo-mesh-mgmt-plane.yaml > _output/gloo-mesh/gloo-mesh-mgmt-plane.yaml

helm install gloo-mesh-enterprise gloo-mesh-enterprise/gloo-mesh-enterprise \
  --kube-context ${MGMT_CONTEXT} \
  --namespace gloo-mesh \
  --version $GLOO_MESH_HELM_VERSION \
  --create-namespace \
  -f _output/gloo-mesh/gloo-mesh-mgmt-plane.yaml

# Wait for pod to become ready
kubectl --context ${MGMT_CONTEXT} wait --for=condition=ready  -n gloo-mesh

export ENDPOINT_GLOO_MESH=$(kubectl --context ${MGMT_CONTEXT} -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].*}'):9900
export HOST_GLOO_MESH=$(echo ${ENDPOINT_GLOO_MESH} | cut -d: -f1)
```

### Deploy Gloo Agents

#### East Cluster

```
kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${EAST_MESH_NAME}
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF

# No longer required becaulse of Vault PKI
#kubectl --context ${EAST_CONTEXT} create ns gloo-mesh
#kubectl get secret relay-root-tls-secret -n gloo-mesh --context ${MGMT_CONTEXT} -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
#kubectl create secret generic relay-root-tls-secret -n gloo-mesh --context ${EAST_CONTEXT} --from-file ca.crt=ca.crt
#rm ca.crt

#kubectl get secret relay-identity-token-secret -n gloo-mesh --context ${MGMT_CONTEXT} -o jsonpath='{.data.token}' | base64 -d > token
#kubectl create secret generic relay-identity-token-secret -n gloo-mesh --context ${EAST_CONTEXT} --from-file token=token
#rm token

# Update CRDs
helm repo add gloo-mesh-agent https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-agent
helm repo update
helm pull gloo-mesh-agent/gloo-mesh-agent --version $GLOO_MESH_HELM_VERSION --untar
kubectl --context ${EAST_CONTEXT} apply -f gloo-mesh-agent/charts/gloo-mesh-crds/crds
rm -rf gloo-mesh-agent

helm install gloo-mesh-agent gloo-mesh-agent/gloo-mesh-agent \
  --kube-context=${EAST_CONTEXT} \
  --namespace gloo-mesh \
  --set cluster=${EAST_MESH_NAME} \
  --set relay.serverAddress=${ENDPOINT_GLOO_MESH} \
  --version $GLOO_MESH_HELM_VERSION \
  --create-namespace \
  -f gloo-mesh-agent.yaml
```

#### West Cluster

```
kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${WEST_MESH_NAME}
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF

# No longer required because of Vault PKI
#kubectl --context ${WEST_CONTEXT} create ns gloo-mesh
#kubectl get secret relay-root-tls-secret -n gloo-mesh --context ${MGMT_CONTEXT} -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
#kubectl create secret generic relay-root-tls-secret -n gloo-mesh --context ${WEST_CONTEXT} --from-file ca.crt=ca.crt
#rm ca.crt

#kubectl get secret relay-identity-token-secret -n gloo-mesh --context ${MGMT_CONTEXT} -o jsonpath='{.data.token}' | base64 -d > token
#kubectl create secret generic relay-identity-token-secret -n gloo-mesh --context ${WEST_CONTEXT} --from-file token=token
#rm token

helm pull gloo-mesh-agent/gloo-mesh-agent --version $GLOO_MESH_HELM_VERSION --untar
kubectl --context ${WEST_CONTEXT} apply -f gloo-mesh-agent/charts/gloo-mesh-crds/crds
rm -rf gloo-mesh-agent

helm install gloo-mesh-agent gloo-mesh-agent/gloo-mesh-agent \
  --kube-context=${WEST_CONTEXT} \
  --namespace gloo-mesh \
  --set cluster=${WEST_MESH_NAME} \
  --set relay.serverAddress=${ENDPOINT_GLOO_MESH} \
  --version $GLOO_MESH_HELM_VERSION \
  --create-namespace \
  -f gloo-mesh-agent.yaml
```

#### Deploy Addons

```
kubectl --context ${EAST_CONTEXT} create namespace gloo-mesh-addons
kubectl --context ${EAST_CONTEXT} label namespace gloo-mesh-addons istio.io/rev=$REVISION
kubectl --context ${WEST_CONTEXT} create namespace gloo-mesh-addons
kubectl --context ${WEST_CONTEXT} label namespace gloo-mesh-addons istio.io/rev=$REVISION

helm install gloo-mesh-agent-addons gloo-mesh-agent/gloo-mesh-agent \
  --namespace gloo-mesh-addons \
  --kube-context=${EAST_CONTEXT} \
  --set glooMeshAgent.enabled=false \
  --set rate-limiter.enabled=true \
  --set ext-auth-service.enabled=true \
  --version $GLOO_MESH_HELM_VERSION

helm install gloo-mesh-agent-addons gloo-mesh-agent/gloo-mesh-agent \
  --namespace gloo-mesh-addons \
  --kube-context=${WEST_CONTEXT} \
  --set glooMeshAgent.enabled=false \
  --set rate-limiter.enabled=true \
  --set ext-auth-service.enabled=true \
  --version $GLOO_MESH_HELM_VERSION
```