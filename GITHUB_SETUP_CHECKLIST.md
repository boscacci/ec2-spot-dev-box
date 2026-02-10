# GitHub Actions Setup Checklist

Before running the workflow from your phone, verify these settings are configured in GitHub.

## Quick Links

- **Repository**: https://github.com/boscacci/iac-dev-box
- **Settings**: https://github.com/boscacci/iac-dev-box/settings
- **Secrets/Variables**: https://github.com/boscacci/iac-dev-box/settings/secrets/actions

## Required Configuration

**The workflow uses repository-level secrets and variables** (no GitHub Environment required).

Go to: **Settings → Secrets and variables → Actions**

### Repository Secrets

| Secret Name | Value | Source |
|------------|-------|--------|
| `AWS_ROLE_ARN` | `arn:aws:iam::YOUR_ACCOUNT_ID:role/iac-dev-box-gha-terraform-...` | `terraform -chdir=bootstrap output -raw gha_terraform_role_arn` |
| `DEVBOX_ADDITIONAL_SSH_KEYS` | Your SSH public keys (see below) | `./scripts/prepare_ssh_keys.sh` |

### Repository Variables

| Variable Name | Value | Source |
|--------------|-------|--------|
| `TF_STATE_BUCKET` | `iac-dev-box-tfstate-YOUR_ACCOUNT_ID-us-west-2` | `terraform -chdir=bootstrap output -raw tf_state_bucket` |
| `TF_STATE_KEY` | `iac-dev-box/us-west-2/terraform.tfstate` | `terraform -chdir=bootstrap output -raw tf_state_key` |
| `TF_LOCK_TABLE` | `iac-dev-box-tf-locks-YOUR_ACCOUNT_ID-us-west-2` | `terraform -chdir=bootstrap output -raw tf_lock_table` |
| `TF_STATE_REGION` | `us-west-2` | Your AWS region |
| `DEVBOX_KEY_NAME` | `dev-box` | Your EC2 key pair name |

**Note:** If you prefer environment-level config (e.g. for approvals), create a "dev-box" environment and add `environment: dev-box` back to the workflow; then put these secrets/variables in that environment instead.

## SSH Keys Setup

Run this to see your formatted SSH public keys:

```bash
./scripts/prepare_ssh_keys.sh
```

Or manually:

```bash
cat ~/.ssh/id_rsa.pub ~/.ssh/dev-box.pem.pub
```

Copy the output and paste it into the `DEVBOX_ADDITIONAL_SSH_KEYS` secret.

**Format** (multiple keys, one per line):
```
ssh-rsa AAAAB3NzaC1yc2EAAAA... user@host1
ssh-rsa AAAAB3NzaC1yc2EAAAA... user@host2
```

## Verification

### 1. Check Bootstrap Outputs

```bash
cd bootstrap
terraform output
```

Should show:
- ✅ `gha_terraform_role_arn`
- ✅ `tf_state_bucket`
- ✅ `tf_lock_table`
- ✅ `tf_state_key`

### 2. Check AWS Secrets Manager

```bash
aws secretsmanager describe-secret --secret-id CLAUDE_API_KEY --region us-west-2
```

Should show:
- ✅ Secret exists
- ✅ Name: `CLAUDE_API_KEY`
- ✅ Region: `us-west-2`

### 3. Check EC2 Key Pair

```bash
aws ec2 describe-key-pairs --key-names dev-box --region us-west-2
```

Should show:
- ✅ Key pair `dev-box` exists

### 4. Validate Workflow Locally

```bash
./scripts/test_workflow.sh
```

Should show:
- ✅ All workflow logic tests passed!

## Testing the Workflow

### From Desktop

1. Go to: https://github.com/boscacci/iac-dev-box/actions/workflows/dev-box.yml
2. Click **Run workflow** button
3. Select:
   - Branch: `main`
   - **action**: `plan` (safe - just shows what would change)
   - **flavor**: Leave blank
4. Click **Run workflow**
5. Monitor the run - should complete in ~1 minute

### From Phone

1. Open GitHub mobile app
2. Navigate to your repository
3. Tap **Actions** tab
4. Tap **dev-box** workflow
5. Tap **Run workflow**
6. Select:
   - **What to do**: `start`
   - **Instance size**: `Large: 4 vCPU, 32GB RAM (~$0.15/hr)`
7. Tap **Run workflow**
8. Monitor progress (should complete in ~3 minutes)

## Common Issues

### Issue: "Missing AWS_ROLE_ARN"

**Solution**: Add the role ARN to GitHub secrets:
```bash
cd bootstrap
terraform output -raw gha_terraform_role_arn
```
Copy the output and add as `AWS_ROLE_ARN` secret.

### Issue: "Missing TF_STATE_BUCKET"

**Solution**: Add all Terraform backend variables:
```bash
cd bootstrap
terraform output
```
Copy each value to the corresponding GitHub variable.

### Issue: "Missing EC2 key pair name"

**Solution**: Add `DEVBOX_KEY_NAME` variable with value `dev-box`.

### Issue: Workflow fails with "InvalidClientTokenId"

**Solution**: The OIDC trust relationship may be wrong. Check:
1. Bootstrap was run with correct `github_repo` variable
2. You're running from the `main` branch
3. Repository name is exactly `boscacci/iac-dev-box`

### Issue: "Secret not found: CLAUDE_API_KEY"

**Solution**: Create the secret in AWS Secrets Manager:
```bash
aws secretsmanager create-secret \
  --name CLAUDE_API_KEY \
  --secret-string "YOUR_ANTHROPIC_KEY..." \
  --region us-west-2
```

## Success Criteria

When everything is configured correctly:

✅ Workflow runs without errors  
✅ Instance launches in ~2-3 minutes  
✅ SSH works with your keys  
✅ Claude API key is set  
✅ Jupyter and pandas work  

## Next Steps After First Successful Run

1. SSH into the instance
2. Run the verification script:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/boscacci/iac-dev-box/main/scripts/verify_setup.sh | bash
   ```
3. Test Jupyter:
   ```bash
   conda activate sr
   jupyter lab --ip=0.0.0.0 --no-browser
   ```

## Quick Reference

**Your bootstrap values** (from earlier):
- State bucket: `iac-dev-box-tfstate-YOUR_ACCOUNT_ID-us-west-2`
- Lock table: `iac-dev-box-tf-locks-YOUR_ACCOUNT_ID-us-west-2`
- State key: `iac-dev-box/us-west-2/terraform.tfstate`
- Role ARN: `arn:aws:iam::YOUR_ACCOUNT_ID:role/iac-dev-box-gha-terraform-...`

**Claude secret** (us-west-2):
- ARN: `arn:aws:secretsmanager:us-west-2:YOUR_ACCOUNT_ID:secret:CLAUDE_API_KEY-oCkuLn`
- Name: `CLAUDE_API_KEY`
