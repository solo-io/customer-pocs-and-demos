# Parrot Analytics - Istio Integration PoC

## Prerequisites

1. Create required env vars

    ```
    export CLUSTER_OWNER="kasunt"
    export CLUSTER_REGION=ap-northeast-1
    export PROJECT="parrot-analytics"

    export CLUSTER_NAME=${CLUSTER_OWNER}-${PROJECT}
    export PARENT_DOMAIN_NAME=${CLUSTER_OWNER}.fe.gl00.net
    export DOMAIN_NAME=${PROJECT}.${CLUSTER_OWNER}.fe.gl00.net

    export GLOO_EDGE_HELM_VERSION=1.11.19
    export GLOO_EDGE_VERSION=v${GLOO_EDGE_HELM_VERSION}
    export REPO=us-docker.pkg.dev/gloo-mesh/istio-a9797008feb0
    export ISTIO_VERSION=1.13.4-solo
    export REVISION=1-13-4
    ```

2. Create output directory structure

    ```
    mkdir -p _output/{gloo,alb-controller,external-dns,cert-manager}
    ```

3. Provision cluster

    ```
    ./cluster-provision/scripts/provision-eks-cluster.sh create -n ${PROJECT} -o ${CLUSTER_OWNER} -a 3 -v 1.22 -r ${CLUSTER_REGION}
    ```

## Deploy Istio

Refer to [installation guide](integrations/ISTIO_INSTALLATION.md).

## Deploy Gloo Edge

This does require with integrations external-dns, alb controller and cert manager. Refer below for instructions.

```
helm repo add glooe https://storage.googleapis.com/gloo-ee-helm
helm repo update

envsubst < gloo-edge-helm-values.yaml > _output/gloo/gloo-edge-helm-values.yaml
helm install glooee glooe/gloo-ee -n gloo-system \
    --version ${GLOO_EDGE_HELM_VERSION} \
    --create-namespace \
    --set-string license_key=$GLOO_EDGE_LICENSE_KEY \
    -f _output/gloo/gloo-edge-helm-values.yaml
```

## Deploy Application

```
kubectl create ns apps
kubectl create ns apps-configuration
kubectl label namespace apps istio.io/rev=$REVISION

kubectl apply -f apps/httpbin.yaml -n apps
kubectl apply -f apps/httpbin-upstream.yaml
```

### Configuration

```
kubectl apply -f configuration/istio-integration/mtls-peer-authentication.yaml
envsubst < <(cat configuration/httpbin/httpbin-cert.yaml) | kubectl apply -f -
envsubst < <(cat configuration/httpbin/httpbin-vs.yaml) | kubectl apply -f -
```

### Testing and Verification

Look for the `X-Forwarded-Client-Cert` if everything is working as expected

```
curl -iv https://apps.${PROJECT}.${CLUSTER_OWNER}.fe.gl00.net/get

# E.g. result,
{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Host": "apps.parrot-analytics.kasunt.fe.gl00.net",
    "User-Agent": "curl/7.83.1",
    "X-Forwarded-Client-Cert": "By=spiffe://ge-mesh.solo.io/ns/apps/sa/httpbin;Hash=87ef5be8aae37f532e92d00b54f16bf076f4b43d1efc213779547589dd5889f5;Subject=\"\";URI=spiffe://ge-mesh.solo.io/ns/gloo-system/sa/gateway-proxy"
  },
  "origin": "127.0.0.6",
  ....
}
```

## Integrations

Refer to [guide](integrations/EXTERNAL_INTEGRATIONS.md) for alb controller, external-dns and cert-manager.