$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$eksFile = Join-Path $root "modules\eks-auto-mode\eks.tf"
$addonsFile = Join-Path $root "modules\eks-auto-mode\eks-addons.tf"
$eks = Get-Content -Raw -LiteralPath $eksFile
$addons = Get-Content -Raw -LiteralPath $addonsFile

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "ASSERTION FAILED: $Message"
  }
}

Assert-True ($eks -notmatch '(?ms)^\s*exec\s*\{') "Provider exec blocks must not exist."
Assert-True ($eks -notmatch 'command\s*=\s*"aws"') "Provider configuration must not invoke AWS CLI."
Assert-True ($eks -match '(?ms)^ephemeral\s+"aws_eks_cluster_auth"\s+"this"\s*\{.*?name\s*=\s*module\.eks\.cluster_name.*?depends_on\s*=\s*\[module\.eks\].*?\}') "Ephemeral EKS auth must defer until module.eks."

$tokenReferences = [regex]::Matches($eks, 'ephemeral\.aws_eks_cluster_auth\.this\.token').Count
Assert-True ($tokenReferences -eq 3) "Expected three ephemeral token references; found $tokenReferences."

$expectedKubeconfigResource = @'
resource "null_resource" "update_kubeconfig" {
  provisioner "local-exec" {
    command = <<EOT
      # Update Global Config
      ORIGINAL_CONTEXT=$(kubectl config current-context)
      KUBECONFIG=$HOME/.kube/config aws --region ${var.region} eks update-kubeconfig --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}-${var.region}
      kubectl config use-context $ORIGINAL_CONTEXT
      # Update Project Config
      aws --region ${var.region} eks update-kubeconfig --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}-${var.region}
    EOT
  }

  depends_on = [module.eks]
}
'@

$expectedKubeconfigOutput = @'
output "eks_update_kubeconfig" {
  value = "aws --region ${var.region} eks update-kubeconfig --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}-${var.region}"
}
'@

$normalizedEks = ($eks -replace "`r`n", "`n").Trim()
$normalizedKubeconfigResource = ($expectedKubeconfigResource -replace "`r`n", "`n").Trim()
$normalizedKubeconfigOutput = ($expectedKubeconfigOutput -replace "`r`n", "`n").Trim()
Assert-True ($normalizedEks.Contains($normalizedKubeconfigResource)) "update_kubeconfig lifecycle must remain unchanged."
Assert-True ($normalizedEks.Contains($normalizedKubeconfigOutput)) "eks_update_kubeconfig public output must remain unchanged."
Assert-True ($addons -match '(?ms)resource\s+"null_resource"\s+"delete_gp2_storageclass"\s*\{.*?kubectl delete storageclass gp2 --ignore-not-found.*?depends_on\s*=\s*\[module\.eks_blueprints_addons_core\].*?\}') "gp2 cleanup lifecycle must remain unchanged."

Write-Output "Static regression assertions passed."
