graph TB
    subgraph Internet["Internet/External"]
        DNS["Route 53<br/>DNS"]
        Users["Corporate Users<br/>250+ Engineers"]
    end

    subgraph AWS["AWS eu-central-1 Region"]
        subgraph VPC["VPC: 10.0.0.0/16"]
            subgraph PublicSubnets["Public Subnets (2 AZs)"]
                NAT1["NAT Gateway<br/>AZ 1"]
                NAT2["NAT Gateway<br/>AZ 2"]
                ALB["Application Load Balancer<br/>Port 443 HTTPS"]
            end

            subgraph PrivateSubnets["Private Subnets (2 AZs)"]
                subgraph EKSCluster["EKS Cluster: Kubernetes 1.27+"]
                    CPM["Control Plane<br/>AWS Managed"]
                    
                    subgraph NodeGroup1["Node Group 1 - AZ 1<br/>t3.medium/large"]
                        Node1["Node 1"]
                        Node2["Node 2"]
                    end

                    subgraph NodeGroup2["Node Group 2 - AZ 2<br/>t3.medium/large"]
                        Node3["Node 3"]
                        Node4["Node 4"]
                    end

                    subgraph KubeSystem["kube-system Namespace"]
                        Ingress["NGINX Ingress<br/>Controller"]
                        CertMgr["Cert Manager<br/>SSL/TLS"]
                        OTelCollector["OpenTelemetry<br/>Collector"]
                        Monitoring["Prometheus/CloudWatch<br/>Agent"]
                    end

                    subgraph TenantAlpha["Namespace: tenant-alpha"]
                        AlphaPods["Pods<br/>2-10 replicas"]
                        AlphaSvc["Service<br/>ClusterIP"]
                        AlphaNP["Network Policy<br/>Deny-All Ingress"]
                        AlphaRBAC["RBAC<br/>Role/RoleBinding"]
                        AlphaIRSA["IRSA<br/>IAM Role"]
                    end

                    subgraph TenantBeta["Namespace: tenant-beta"]
                        BetaPods["Pods<br/>2-10 replicas"]
                        BetaSvc["Service<br/>ClusterIP"]
                        BetaNP["Network Policy<br/>Deny-All Ingress"]
                        BetaRBAC["RBAC<br/>Role/RoleBinding"]
                        BetaIRSA["IRSA<br/>IAM Role"]
                    end

                    subgraph TenantN["Namespace: tenant-N"]
                        NPods["Pods<br/>2-10 replicas"]
                        NSvc["Service<br/>ClusterIP"]
                        NNP["Network Policy<br/>Deny-All Ingress"]
                        NRBAC["RBAC<br/>Role/RoleBinding"]
                        NIRSA["IRSA<br/>IAM Role"]
                    end
                end

                subgraph DataLayer["Data & Storage Layer"]
                    RDS["RDS PostgreSQL<br/>Multi-AZ<br/>db.t3.large<br/>500 GB Storage"]
                    S3["S3 Bucket<br/>Artifact Storage<br/>1 TB"]
                    ECR["ECR<br/>Container Registry"]
                    Cache["ElastiCache<br/>Optional"]
                end

                subgraph CI_CD["CI/CD Infrastructure"]
                    CodeBuild["AWS CodeBuild<br/>Docker Build"]
                    CodePipeline["AWS CodePipeline<br/>Orchestration"]
                    GH_Actions["GitHub Actions<br/>Trigger/Notify"]
                end
            end

            subgraph SecurityLayer["Security & IAM"]
                SG["Security Groups<br/>Ingress: 443 only"]
                NACL["NACLs<br/>Optional"]
                IAM["IAM Roles & Policies<br/>Least Privilege"]
                Secrets["AWS Secrets Manager<br/>DB Credentials"]
            end
        end

        subgraph Monitoring["Observability Stack"]
            CW_Logs["CloudWatch Logs<br/>Application Logs"]
            CW_Metrics["CloudWatch Metrics<br/>Infrastructure"]
            NewRelic["New Relic<br/>APM & Analytics"]
            OTLP["OTLP Exporter<br/>OpenTelemetry Protocol"]
        end
    end

    %% Connections - External
    DNS -->|DNS Resolution| ALB
    Users -->|HTTPS Requests| DNS

    %% Connections - ALB to Ingress
    ALB -->|Routes Traffic| Ingress

    %% Connections - Ingress to Services
    Ingress -->|Route to Services| AlphaSvc
    Ingress -->|Route to Services| BetaSvc
    Ingress -->|Route to Services| NSvc

    %% Connections - Services to Pods
    AlphaSvc -->|Load Balance| AlphaPods
    BetaSvc -->|Load Balance| BetaPods
    NSvc -->|Load Balance| NPods

    %% Connections - Isolation & Security per Tenant
    AlphaPods -->|Protected by| AlphaNP
    AlphaPods -->|Controlled by| AlphaRBAC
    AlphaPods -->|Assumed Role| AlphaIRSA
    
    BetaPods -->|Protected by| BetaNP
    BetaPods -->|Controlled by| BetaRBAC
    BetaPods -->|Assumed Role| BetaIRSA
    
    NPods -->|Protected by| NNP
    NPods -->|Controlled by| NRBAC
    NPods -->|Assumed Role| NIRSA

    %% Connections - Data Access
    AlphaPods -->|Query via<br/>Tenant Schema| RDS
    BetaPods -->|Query via<br/>Tenant Schema| RDS
    NPods -->|Query via<br/>Tenant Schema| RDS

    AlphaPods -->|S3 API<br/>Tenant Prefix| S3
    BetaPods -->|S3 API<br/>Tenant Prefix| S3
    NPods -->|S3 API<br/>Tenant Prefix| S3

    %% Connections - CI/CD
    GH_Actions -->|Trigger Build| CodeBuild
    CodeBuild -->|Push Image| ECR
    GH_Actions -->|Deploy| CodePipeline
    CodePipeline -->|Deploy Manifests| EKSCluster

    %% Connections - Monitoring
    OTelCollector -->|Collect Metrics| Monitoring
    Monitoring -->|Ingest Logs| CW_Logs
    Monitoring -->|Ingest Metrics| CW_Metrics
    OTLP -->|Export OTLP| NewRelic
    OTelCollector -->|Export to| OTLP

    %% Connections - Security
    AlphaIRSA -->|Assume| IAM
    BetaIRSA -->|Assume| IAM
    NIRSA -->|Assume| IAM
    IAM -->|Retrieve| Secrets
    SG -->|Isolate| VPC

    %% Connections - Egress
    Node1 -->|NAT Egress| NAT1
    Node2 -->|NAT Egress| NAT1
    Node3 -->|NAT Egress| NAT2
    Node4 -->|NAT Egress| NAT2

    %% Styling
    classDef aws fill:#FF9900,stroke:#232F3E,color:#000,stroke-width:2px
    classDef k8s fill:#326CE5,stroke:#000,color:#fff,stroke-width:2px
    classDef tenant fill:#7B68EE,stroke:#000,color:#fff,stroke-width:2px
    classDef security fill:#DC143C,stroke:#000,color:#fff,stroke-width:2px
    classDef monitoring fill:#FF6B6B,stroke:#000,color:#fff,stroke-width:2px

    class AWS,VPC,PublicSubnets,PrivateSubnets,DataLayer,NAT1,NAT2,RDS,S3,ECR,Cache,CodeBuild,CodePipeline,CW_Logs,CW_Metrics,IAM,Secrets aws
    class EKSCluster,KubeSystem,CPM,NodeGroup1,NodeGroup2,Ingress,CertMgr,OTelCollector,Monitoring k8s
    class TenantAlpha,TenantBeta,TenantN,AlphaPods,BetaPods,NPods,AlphaSvc,BetaSvc,NSvc,AlphaNP,BetaNP,NNP,AlphaRBAC,BetaRBAC,NRBAC,AlphaIRSA,BetaIRSA,NIRSA tenant
    class SecurityLayer,SG,NACL,Secrets security
    class Monitoring,NewRelic,OTLP monitoring
