## Integrations on East Cluster

```
kubectl config use-context $EAST_CONTEXT
```

### Certificate Manager

* Create an IAM OIDC identity provider and policy

```
eksctl utils associate-iam-oidc-provider \
    --region $CLUSTER_REGION \
    --cluster ${CLUSTER_OWNER}-${EAST_CLUSTER} \
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
    --cluster=${CLUSTER_OWNER}-${EAST_CLUSTER} \
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
    --kube-context ${EAST_CONTEXT} \
    --create-namespace \
    --version v1.8.1 \
    -f integrations/cert-manager/cert-manager-helm-values.yaml
```