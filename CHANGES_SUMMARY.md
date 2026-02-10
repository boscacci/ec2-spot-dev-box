# Summary of Changes - Dev Box Improvements

## What Was Done

I've implemented all your requirements to make the dev box easy to control from your phone with everything pre-configured. Here's what changed:

### 1. ✅ Better GitHub Actions Workflow

**Changed:** `.github/workflows/dev-box.yml`

- **Before:** Had to type "small", "medium", "large", or "xl" every time
- **Now:** Simple dropdown with L/M/H/XL options:
  - **L** = Large (4 vCPU, 32 GB RAM) - default, ~$0.15/hr
  - **M** = Medium (4 vCPU, 16 GB RAM) - ~$0.08/hr  
  - **H** = High (8 vCPU, 64 GB RAM) - ~$0.30/hr
  - **XL** = Extra Large (same as H)
  - _(blank = keep current size)_

### 2. ✅ SSH Keys Automatically Synced

**Changed:** 
- `variables.tf` - Added `additional_ssh_public_keys` variable
- `main.tf` - Pass keys to userdata
- `scripts/userdata.sh` - Add keys to authorized_keys on boot
- `.github/workflows/dev-box.yml` - Read keys from GitHub Secrets

**How it works:**
- Your SSH public keys are stored in GitHub Secrets (`DEVBOX_ADDITIONAL_SSH_KEYS`)
- Every time an instance starts, your keys are automatically added
- You can SSH in with your WSL2 keys without any manual setup

### 3. ✅ Jupyter & Pandas Ready to Go

**Changed:** `scripts/userdata.sh`

- Creates a conda environment called `sr` on first boot
- Pre-installs: jupyter, jupyterlab, pandas, numpy, matplotlib, seaborn, scikit-learn, ipython
- Auto-activates the `sr` environment when you log in

**To use:**
```bash
# Already activated by default!
conda activate sr  # if needed
jupyter lab --ip=0.0.0.0 --no-browser
```

### 4. ✅ Claude Authenticated

**Already working!** Your Claude API key is:
- Pulled from AWS Secrets Manager on instance boot
- Auto-exported as `ANTHROPIC_API_KEY` and `CLAUDE_API_KEY`
- Ready to use with the `claude` command

## New Files Created

1. **SETUP_GUIDE.md** - Complete setup instructions for new users
2. **scripts/verify_setup.sh** - Verification script to test everything works
3. **scripts/prepare_ssh_keys.sh** - Helper to format SSH keys for GitHub
4. **CHANGES_SUMMARY.md** - This file

## What You Need to Do Now

### Step 1: Set up GitHub Secret for SSH Keys

Run this command to see your formatted SSH keys:

```bash
./scripts/prepare_ssh_keys.sh
```

Or get them directly:
```bash
cat ~/.ssh/*.pub
```

Copy the output (both keys) and:
1. Go to GitHub: **Settings → Secrets and variables → Actions**
2. Click **New repository secret** (or environment secret if using environments)
3. Name: `DEVBOX_ADDITIONAL_SSH_KEYS`
4. Value: Paste both SSH public keys (one per line)
5. Click **Add secret**

**Your keys to copy:**
```text
ssh-rsa AAAA... your_name@your_machine
ssh-rsa AAAA... your_email@example.com
```

### Step 2: Test the New Workflow

Once you've added the SSH keys secret:

1. **From your phone** (GitHub mobile app):
   - Go to **Actions → dev-box → Run workflow**
   - Select `action: start`
   - Select `flavor: L` (or M/H as needed)
   - Tap **Run workflow**

2. **Wait for the workflow to complete** (~3-5 minutes)

3. **Connect and verify**:
   ```bash
   # From your laptop
   terraform output -raw ssh_host
   ssh -i ~/.ssh/dev-box.pem ec2-user@<ip-address>
   
   # Or from your phone (using the IP from Actions output)
   ssh ec2-user@<ip-address>
   ```

4. **Run the verification script** on the instance:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/boscacci/iac-dev-box/main/scripts/verify_setup.sh | bash
   ```

## Testing Checklist

After your first launch, verify these work:

- [ ] SSH keys: Can you connect without manually adding keys?
- [ ] Claude: Run `echo $ANTHROPIC_API_KEY` - does it show your key?
- [ ] Conda sr env: Run `conda env list` - is `sr` there?
- [ ] Jupyter: Run `conda activate sr && jupyter --version` - does it work?
- [ ] Pandas: Run `python -c "import pandas; print(pandas.__version__)"` - does it work?
- [ ] Persistent data: Create a file in `/data/test.txt` and verify it survives a stop/start cycle

## Troubleshooting

### SSH Keys Not Working
- Check that `DEVBOX_ADDITIONAL_SSH_KEYS` is set in GitHub Secrets
- Verify you copied the **public** keys (ending in `.pub`), not private keys
- Check the workflow logs for any errors during tfvars generation

### Conda Environment Not Found
The `sr` environment is created on first boot. If it's missing:
```bash
source /data/miniforge3/etc/profile.d/conda.sh
conda create -y -n sr python=3.11 jupyter jupyterlab pandas numpy matplotlib seaborn scikit-learn
```

### Claude Not Authenticated
```bash
# Refresh the API key
claude_key_refresh
echo $ANTHROPIC_API_KEY
```

## Cost Savings

With the new L/M/H options, you can easily match instance size to your workload:

- **Light work** (reviewing code, small scripts): M (~$0.08/hr = $0.64 for 8 hours)
- **Normal work** (development, medium datasets): L (~$0.15/hr = $1.20 for 8 hours)
- **Heavy work** (large datasets, compiling): H (~$0.30/hr = $2.40 for 8 hours)

Plus automatic shutdown after 90 minutes saves even more!

## What's Next

1. **Set up the SSH keys secret** (see Step 1 above)
2. **Test launch from your phone** 
3. **Verify everything works** with the verification script
4. **Enjoy your phone-controlled dev box!** 🚀

All your code in `/data/repos` persists across launches, Claude is ready to go, and Jupyter is just a `conda activate sr` away.

## Files Changed

- `.github/workflows/dev-box.yml` - Better workflow with L/M/H/XL dropdown
- `main.tf` - Pass SSH keys to userdata
- `variables.tf` - Add additional_ssh_public_keys variable
- `scripts/userdata.sh` - Add SSH keys to authorized_keys, create sr conda env
- `README.md` - Updated with new workflow info
- `SETUP_GUIDE.md` - **NEW** - Complete setup guide
- `scripts/verify_setup.sh` - **NEW** - Verification script
- `scripts/prepare_ssh_keys.sh` - **NEW** - SSH key formatter
- `CHANGES_SUMMARY.md` - **NEW** - This file

## Rollback (if needed)

All changes follow infrastructure-as-code principles. If you need to rollback:

```bash
git log --oneline  # find the commit before changes
git revert <commit-hash>
```

---

**Questions?** Check the [SETUP_GUIDE.md](SETUP_GUIDE.md) or the updated [README.md](README.md).
