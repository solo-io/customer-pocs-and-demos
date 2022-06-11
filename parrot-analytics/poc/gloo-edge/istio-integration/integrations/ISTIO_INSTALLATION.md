# Istio Installation

## Install Istio Operator

```
kubectl create namespace istio-system
kubectl create namespace istio-config

istioctl operator init --watchedNamespaces=istio-system
```

## Install Istio Control Plane

```
export MESH_NAME="ge-mesh"
export MESH_DOMAIN="cluster.local"

export PROXY_IMAGE_NAME="proxyv2"
export ISTIO_TOKEN_AUD="istio-ca"

cat <<EOF | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-control-plane
  namespace: istio-system
spec:
  profile: minimal
  hub: ${REPO}
  tag: ${ISTIO_VERSION}
  revision: ${REVISION}

  # Override mesh wide settings
  meshConfig:
    # Enable access logging.
    accessLogFile: /dev/stdout
    # Encoding for the proxy access log.
    accessLogEncoding: JSON
    # Custom format
    accessLogFormat: '{
      "start_time": "%START_TIME%",
      "authority": "%REQ(:AUTHORITY)%",
      "bytes_received": "%BYTES_RECEIVED%",
      "bytes_sent": "%BYTES_SENT%",
      "downstream_local_address": "%DOWNSTREAM_LOCAL_ADDRESS%",
      "downstream_remote_address": "%DOWNSTREAM_REMOTE_ADDRESS%",
      "duration": "%DURATION%",
      "method": "%REQ(:METHOD)%",
      "path": "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%",
      "protocol": "%PROTOCOL%",
      "requested_server_name": "%REQUESTED_SERVER_NAME%",
      "response_code": "%RESPONSE_CODE%",
      "response_flags": "%RESPONSE_FLAGS%",
      "route_name": "%ROUTE_NAME%",
      "upstream_cluster": "%UPSTREAM_CLUSTER%",
      "upstream_host": "%UPSTREAM_HOST%",
      "upstream_local_address": "%UPSTREAM_LOCAL_ADDRESS%",
      "upstream_service_time": "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%",
      "upstream_transport_failure_reason": "%UPSTREAM_TRANSPORT_FAILURE_REASON%",
      "user_agent": "%REQ(USER-AGENT)%",
      "x_forwarded_for": "%REQ(X-FORWARDED-FOR)%",
      "x_user_id": "%REQ(X-USER-ID)%", 
      "x_tenant_id": "%REQ(X-TENANT-ID)%", 
      "baggage": "%REQ(BAGGAGE)%"
    }'

    # Disable tracing
    enableTracing: false

    defaultConfig:
      # Wait for the istio-proxy to start before application pods
      holdApplicationUntilProxyStarts: true

      proxyMetadata:
        # Enable Istio agent to handle DNS requests for known hosts
        # Unknown hosts will automatically be resolved using upstream dns servers in resolv.conf
        ISTIO_META_DNS_CAPTURE: "true"
        # Enable automatic address allocation (optional)
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
    
    # Specify if http1.1 connections should be upgraded to http2 by default. 
    # Can be overridden using DestinationRule
    h2UpgradePolicy: UPGRADE

    # Set the default behavior of the sidecar for handling outbound traffic from the application.
    outboundTrafficPolicy:
      mode: ALLOW_ANY
    # The trust domain corresponds to the trust root of a system.
    trustDomain: ${MESH_NAME}.solo.io
    # The namespace to treat as the administrative root namespace for Istio configuration.
    rootNamespace: istio-config

  # Traffic management feature
  components:
    base:
      enabled: true
    pilot:
      enabled: true
      k8s:
        replicaCount: 1
        resources:
          requests:
            cpu: 200m
            memory: 200Mi
        env:
        # Allow multiple trust domains
        - name: PILOT_SKIP_VALIDATE_TRUST_DOMAIN
          value: "true"
        - name: ISTIOD_CUSTOM_HOST
          value: istiod.${DOMAIN_NAME}

    # Disable Istio CNI feature
    cni:
      enabled: false

    # Istio Gateway feature
    # Disable gateways deployments because they will be in separate IstioOperator configs
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
    - name: istio-eastwestgateway
      enabled: false
    egressGateways:
    - name: istio-egressgateway
      enabled: false

  # Helm values overrides
  values:
    global:
      meshID: ${MESH_NAME}
      network: ${MESH_NAME}-network
      # Needed for annotating istio metrics with cluster name
      multiCluster:
        clusterName: ${MESH_NAME}

    # Custom sidecar injector for Gloo proxy to enable mTLS upstream
    sidecarInjectorWebhook:
      templates:
        glooTemplate: |
          spec:
            containers:
              - name: sds
                image: quay.io/solo-io/sds:1.10.18
                imagePullPolicy: IfNotPresent
                resources: {}
                ports:
                  - name: sds
                    containerPort: 8234
                    protocol: TCP
                env:
                  - name: POD_NAME
                    valueFrom:
                      fieldRef:
                        apiVersion: v1
                        fieldPath: metadata.name
                  - name: POD_NAMESPACE
                    valueFrom:
                      fieldRef:
                        apiVersion: v1
                        fieldPath: metadata.namespace
                  - name: ISTIO_MTLS_SDS_ENABLED
                    value: "true"
                volumeMounts:
                  - name: istio-certs
                    mountPath: /etc/istio-certs/
                  - name: envoy-config
                    mountPath: /etc/envoy
              - name: istio-proxy
                image: "${REPO}/${PROXY_IMAGE_NAME}:${ISTIO_VERSION}"
                imagePullPolicy: IfNotPresent
                args:
                  - proxy
                  - sidecar
                  - --domain
                  - \$\(POD_NAMESPACE\).svc.${MESH_DOMAIN}
                  - --proxyLogLevel={{ annotation .ObjectMeta \`sidecar.istio.io/logLevel\` "warning" }}
                  - --proxyComponentLogLevel={{ annotation .ObjectMeta \`sidecar.istio.io/componentLogLevel\` "misc:error" }}
                  - --log_output_level={{ annotation .ObjectMeta \`sidecar.istio.io/agentLogLevel\` "default:info" }}
                ports:
                  - name: http-envoy-prom
                    containerPort: 15090
                    protocol: TCP
                env:
                  - name: OUTPUT_CERTS
                    value: /etc/istio-certs
                  - name: JWT_POLICY
                    value: third-party-jwt
                  - name: PILOT_CERT_PROVIDER
                    value: istiod
                  - name: CA_ADDR
                    value: "{{ .ProxyConfig.DiscoveryAddress }}"
                  - name: ISTIO_META_MESH_ID
                    value: "{{ .MeshConfig.TrustDomain }}"
                  - name: POD_NAME
                    valueFrom:
                      fieldRef:
                        fieldPath: metadata.name
                  - name: POD_NAMESPACE
                    valueFrom:
                      fieldRef:
                        fieldPath: metadata.namespace
                  - name: INSTANCE_IP
                    valueFrom:
                      fieldRef:
                        fieldPath: status.podIP
                  - name: SERVICE_ACCOUNT
                    valueFrom:
                      fieldRef:
                        fieldPath: spec.serviceAccountName
                  - name: HOST_IP
                    valueFrom:
                      fieldRef:
                        fieldPath: status.hostIP
                  - name: ISTIO_META_POD_NAME
                    valueFrom:
                      fieldRef:
                        apiVersion: v1
                        fieldPath: metadata.name
                  - name: ISTIO_META_CONFIG_NAMESPACE
                    valueFrom:
                      fieldRef:
                        apiVersion: v1
                        fieldPath: metadata.namespace
                  - name: PROXY_CONFIG
                    value: |
                      {{ protoToJSON .ProxyConfig }}
                resources:
                  limits:
                    cpu: "2"
                    memory: 1Gi
                  requests:
                    cpu: 100m
                    memory: 128Mi
                readinessProbe:
                  failureThreshold: 30
                  httpGet:
                    path: /healthz/ready
                    port: 15021
                    scheme: HTTP
                  initialDelaySeconds: 1
                  periodSeconds: 2
                  successThreshold: 1
                  timeoutSeconds: 3
                volumeMounts:
                  - name: istiod-ca-cert
                    mountPath: /var/run/secrets/istio
                  - name: istio-certs
                    mountPath: /etc/istio-certs/
                  - name: istio-data
                    mountPath: /var/lib/istio/data
                  - name: istio-envoy
                    mountPath: /etc/istio/proxy
                  - name: istio-token
                    mountPath: /var/run/secrets/tokens
            volumes:
            - name: istio-envoy
              emptyDir:
                medium: Memory
            - name: istio-data
              emptyDir: {}
            - name: istio-certs
              emptyDir:
                medium: Memory
            - name: istiod-ca-cert
              configMap:
                name: istio-ca-root-cert
                defaultMode: 420
            - name: envoy-config
              configMap:
                name: gateway-proxy-envoy-config
                defaultMode: 420
            - name: istio-token
              projected:
                sources:
                  - serviceAccountToken:
                      path: istio-token
                      expirationSeconds: 43200
                      audience: ${ISTIO_TOKEN_AUD}
            - name: istio-podinfo
              downwardAPI:
                defaultMode: 420
                items:
                  - fieldRef:
                      apiVersion: v1
                      fieldPath: metadata.labels
                    path: labels
                  - fieldRef:
                      apiVersion: v1
                      fieldPath: metadata.annotations
                    path: annotations
EOF
```