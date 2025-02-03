
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.8.0"

  cluster_name    = local.name
  cluster_version = "1.28"

  vpc_id = var.vpc_id

  subnet_ids= var.subnet_ids                  


  tags = local.default_tags
  cluster_endpoint_public_access = true
  cluster_endpoint_public_access_cidrs = [ "0.0.0.0/0" ]
  cluster_security_group_additional_rules = {
    egress_nodes_ephemeral_ports_tcp = {
      cidr_blocks = ["0.0.0.0/0"]
      description = "Allow all traffic from remote node/pod network"
      from_port   = 0
      to_port     = 0
      protocol    = "all"
      type        = "egress"

    }
      ingress_nodes_ephemeral_ports_tcp = {
      cidr_blocks = ["0.0.0.0/0"]
      description = "Allow all traffic from remote node/pod network"
      from_port   = 0
      to_port     = 0
      protocol    = "all"
      type        = "ingress"

    }
  }

  node_security_group_additional_rules = {
    ingress_cluster_api_ephemeral_ports_tcp = {
      cidr_blocks = ["0.0.0.0/0"]
      description = "Allow all traffic from remote node/pod network"
      from_port   = 0
      to_port     = 0
      protocol    = "all"
      type        = "ingress"
    }

  }

  eks_managed_node_groups = {
    initial = {
      min_size     = 1
      max_size     = 3
      desired_size = 1

      instance_types = ["t3.medium"]
    }
  }
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "https://charts.karpenter.sh"
  chart      = "karpenter"

  set {
    name  = "replicas"
    value = "1"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_irsa.iam_role_arn
  }

  set {
    name  = "clusterName"
    value = local.name
  }

  set {
    name  = "clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "webhook.enabled"
    value = "true"
  }

  depends_on = [module.eks]

}


module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "karpenter-controller-role"

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:karpenter"]
    }
  }

  role_policy_arns = {
    policy = aws_iam_policy.karpenter.arn
  }
}

resource "aws_iam_policy" "karpenter" {
  name        = "karpenter-policy"
  description = "Policy for Karpenter to manage EC2 instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "ec2:RunInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:TerminateInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:CreateTags",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeImages",
          "iam:PassRole",
          "sts:AssumeRoleWithWebIdentity",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:CreateLaunchTemplate",
          "ssm:GetParameter",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "iam:CreateServiceLinkedRole",
          "ec2:DeleteLaunchTemplate",
          "ec2:DeleteLaunchTemplateVersions",
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ]
        Resource = "*"
      }
    ]
  })
}


resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile"
  role = module.eks.eks_managed_node_groups.initial.iam_role_name
}

resource "kubectl_manifest" "karpenter_provisioner_graviton" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: arm64
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot"]
        - key: "node.kubernetes.io/instance-type"
          operator: In
          values: ["m6g.medium", "m5.large", "m6g.xlarge", "c6g.xlarge" ]
      providerRef:
        name: default
      ttlSecondsAfterEmpty: 60
      limits:
        resources:
          cpu: 100
          memory: 1000Gi
  YAML

  depends_on = [helm_release.karpenter]
}


resource "kubectl_manifest" "karpenter_provisioner_amd" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: amd64
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot"]
        - key: "node.kubernetes.io/instance-type"
          operator: In
          values: ["m6g.medium", "m5.large", "m6g.xlarge", "c6g.xlarge" ]
      providerRef:
        name: default
      ttlSecondsAfterEmpty: 60
      limits:
        resources:
          cpu: 100
          memory: 1000Gi
  YAML

  depends_on = [helm_release.karpenter]
}
resource "kubectl_manifest" "karpenter_node_template" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1alpha1
    kind: AWSNodeTemplate
    metadata:
      name: default
    spec:
      subnetSelector:
        aws-ids: "${var.subnet_ids[0]}"
      securityGroupSelector:
        aws-ids: "${var.security_group}"
      instanceProfile: KarpenterNodeInstanceProfile
      tags:
        karpenter.sh/discovery: "${local.name}"
  YAML

  depends_on = [helm_release.karpenter]
}