## Integrations

### External DNS

* Create an IAM OIDC identity provider and policy

    ```
    eksctl utils associate-iam-oidc-provider \
        --region $CLUSTER_REGION \
        --cluster $CLUSTER_NAME \
        --approve

    aws iam create-policy \
        --policy-name kasunt_AmazonExternalDNSRoute53Policy \
        --description "Allow access to Route53 Resources for ExternalDNS" \
        --policy-document file://integrations/external-dns/iam-policy.json
    ```

* Create an IAM role

    ```
    eksctl create iamserviceaccount \
        --name=external-dns \
        --namespace=external-dns \
        --cluster=$CLUSTER_NAME \
        --region=$CLUSTER_REGION \
        --attach-policy-arn=$(aws iam list-policies --query 'Policies[?PolicyName==`kasunt_AmazonExternalDNSRoute53Policy`].Arn' --output text) \
        --approve \
        --override-existing-serviceaccounts
    ```

* Create the hosted zone

    ```
    aws route53 create-hosted-zone --name "$DOMAIN_NAME." --caller-reference "${CLUSTER_NAME}-$(date +%s)"
    ```

* Add the nameservers to the top level zone

    ```
    TOP_LEVEL_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$PARENT_DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
    export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
    NS_LIST=$(aws route53 list-resource-record-sets --output json --hosted-zone-id "$HOSTED_ZONE_ID" \
        | jq -r '.ResourceRecordSets' | jq -r 'map(select(.Type == "NS"))' | jq -r '.[0].ResourceRecords')

    aws route53 change-resource-record-sets \
    --hosted-zone-id "$TOP_LEVEL_HOSTED_ZONE_ID" \
    --change-batch file://<(cat << EOF
    {
        "Comment": "$DOMAIN_NAME nameservers",
        "Changes": [
            {
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": "$DOMAIN_NAME",
                    "Type": "NS",
                    "TTL": 120,
                    "ResourceRecords": $NS_LIST
                }
            }
        ]
    }
    EOF
    )
    ```

* Deploy External DNS

    ```
    helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
    helm repo update

    envsubst < integrations/external-dns/external-dns-helm-values.yaml > _output/external-dns/external-dns-helm-values.yaml
    helm install external-dns external-dns/external-dns -n external-dns --create-namespace -f _output/external-dns/external-dns-helm-values.yaml
    ```

### AWS Load Balancer Controller

* Create an IAM OIDC identity provider and policy

    ```
    eksctl utils associate-iam-oidc-provider \
        --region $CLUSTER_REGION \
        --cluster $CLUSTER_NAME \
        --approve

    aws iam create-policy \
        --policy-name kasunt_AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://integrations/alb-controller/iam-policy.json
    ```

* Create an IAM service account

    ```
    eksctl create iamserviceaccount \
        --name=aws-load-balancer-controller \
        --namespace=kube-system \
        --cluster=$CLUSTER_NAME \
        --region=$CLUSTER_REGION \
        --attach-policy-arn=$(aws iam list-policies --query 'Policies[?PolicyName==`kasunt_AWSLoadBalancerControllerIAMPolicy`].Arn' --output text) \
        --override-existing-serviceaccounts \
        --approve
    ```

* Get the VPC ID

    ```
    export VPC_ID=$(aws ec2 describe-vpcs --region $CLUSTER_REGION --filters Name=tag:Name,Values=eksctl-$CLUSTER_NAME-cluster/VPC | jq -r '.Vpcs[]|.VpcId')
    ```

* Install ALB controller

    ```
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update

    envsubst < integrations/alb-controller/alb-controller-helm-values.yaml > _output/alb-controller/alb-controller-helm-values.yaml
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system -f _output/alb-controller/alb-controller-helm-values.yaml
    ```

### Certificate Manager

* Create an IAM OIDC identity provider and policy

    ```
    eksctl utils associate-iam-oidc-provider \
        --region $CLUSTER_REGION \
        --cluster $CLUSTER_NAME \
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
        --cluster=$CLUSTER_NAME \
        --region=$CLUSTER_REGION \
        --attach-policy-arn=$(aws iam list-policies --query 'Policies[?PolicyName==`kasunt_AWSCertManagerRoute53IAMPolicy`].Arn' --output text) \
        --override-existing-serviceaccounts \
        --approve
    ```

* Install cert-manager

    ```
    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.6.2 -f integrations/cert-manager/cert-manager-helm-values.yaml
    ```

* Cluster wide issuer

    ```
    envsubst < <(cat integrations/cert-manager/certificate-issuer.yaml) | kubectl apply -f -
    ```