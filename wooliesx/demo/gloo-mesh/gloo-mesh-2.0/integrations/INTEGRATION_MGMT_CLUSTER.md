# Integrations on Mgmt Cluster

```
kubectl config use-context $MGMT_CONTEXT
```

### Certificate Manager

* Create an IAM OIDC identity provider and policy

```
eksctl utils associate-iam-oidc-provider \
    --region $CLUSTER_REGION \
    --cluster ${CLUSTER_OWNER}-${MGMT_CLUSTER} \
    --approve

aws iam create-policy \
    --policy-name kasunt_AWSCertManagerRoute53IAMPolicy \
    --policy-document file://integrations/cert-manager/iam-policy.json
```

* Create an IAM service account

```
eksctl create iamserviceaccount \
    --name=cert-manager \
    --namespace=cert-manager \
    --cluster=${CLUSTER_OWNER}-${MGMT_CLUSTER} \
    --region=$CLUSTER_REGION \
    --attach-policy-arn=$(aws iam list-policies --query 'Policies[?PolicyName==`kasunt_AWSCertManagerRoute53IAMPolicy`].Arn' --output text) \
    --override-existing-serviceaccounts \
    --approve
```

* Install cert-manager

```
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager -n cert-manager \
    --kube-context ${MGMT_CONTEXT} \
    --create-namespace \
    --version v1.8.1 \
    -f integrations/cert-manager/cert-manager-helm-values.yaml
```

* Cluster wide issuer

```
envsubst < integrations/cert-manager/certificate-issuer.yaml > _output/cert-manager/certificate-issuer.yaml
kubectl apply -f _output/cert-manager/certificate-issuer.yaml
```

### Vault

```
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault -n vault \
    --kube-context ${MGMT_CONTEXT} \
    --create-namespace \
    -f integrations/vault/vault-helm-values.yaml

# Wait for vault to be ready
kubectl wait --for=condition=ready pod vault-0 -n vault
```