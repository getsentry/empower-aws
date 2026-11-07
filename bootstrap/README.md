# One-time AWS admin setup

Creates the GitHub Actions deploy role for this repo. Run once, as an admin of the target AWS account, in AWS CloudShell:

```bash
curl -fsSLO https://raw.githubusercontent.com/getsentry/empower-aws/main/bootstrap/admin-setup.sh
less admin-setup.sh   # optional: review first
bash admin-setup.sh
```

It prints the account and everything it will create, and asks before changing anything. Send the role ARN it prints to the demo owners. `bash admin-setup.sh --delete` undoes it.

What it creates:

- The GitHub Actions OIDC identity provider, if missing.
- `empower-aws-boundary`: caps every role the demo creates to Bedrock, logs, image pulls and secret reads.
- `github-empower-aws-deploy`: assumable only by this repo's GitHub Actions. PowerUserAccess limited to us-east-1, plus IAM rights only for `empower-aws-*` roles that carry the boundary.
