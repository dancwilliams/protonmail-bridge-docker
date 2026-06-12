import requests, os, sys, subprocess


def git(command):
    """Run a git command, raising if it fails."""
    subprocess.run(f"git {command}", shell=True, check=True)


def git_output(command):
    """Run a git command and return its stripped stdout (empty on failure)."""
    result = subprocess.run(f"git {command}", shell=True, capture_output=True, text=True)
    return result.stdout.strip()


token = os.environ.get("GITHUB_TOKEN")
repo  = os.environ.get("GITHUB_REPOSITORY")

# Authenticate the upstream read when possible to avoid shared-runner rate limits.
api_headers = {"Accept": "application/vnd.github.v3+json"}
if token:
    api_headers["Authorization"] = f"token {token}"

# Get latest upstream release
try:
    resp = requests.get(
        "https://api.github.com/repos/ProtonMail/proton-bridge/releases/latest",
        headers=api_headers,
        timeout=30,
    )
    resp.raise_for_status()
    version = resp.json()["tag_name"]
except (requests.RequestException, KeyError, ValueError) as e:
    print(f"Failed to fetch latest upstream release: {e}")
    exit(1)

print(f"Latest upstream release: {version}")

# Read current version
with open("VERSION", 'r') as f:
    current_version = f.read().strip()

if version == current_version:
    print("Already up to date.")
    exit(0)

print(f"New version detected: {current_version} -> {version}")

# Don't push anything during pull_request runs (used for testing this script itself)
is_pull_request = len(sys.argv) > 1 and sys.argv[1] == "true"
if is_pull_request:
    print("Pull request run — skipping push.")
    exit(0)

branch = f"bump/{version}"

# Idempotency guard: the schedule fires daily, but a bump branch is only merged
# when a human acts on the PR. If the branch already exists on the remote (the PR
# is still open, or was closed without deleting the branch), recreating it would
# push a non-fast-forward ref and fail the job on every run. Treat that as a
# successful no-op instead of spamming failures. Delete the remote branch to retrigger.
if git_output(f"ls-remote --heads origin {branch}"):
    print(f"Branch {branch} already exists on the remote — PR already opened. Nothing to do.")
    exit(0)

# Write new version
with open("VERSION", 'w') as f:
    f.write(version + "\n")

# Configure git identity
git("config --local user.name 'GitHub Actions'")
git("config --local user.email 'actions@github.com'")

# Create and push a branch for the version bump
git(f"checkout -b {branch}")
git("add VERSION")
git(f'commit -m "Bump version to {version}"')

push = subprocess.run(f"git push origin {branch}", shell=True)
if push.returncode != 0:
    print("Git push failed!")
    exit(1)

# Open a pull request via GitHub API
upstream_url = f"https://github.com/ProtonMail/proton-bridge/releases/tag/{version}"

pr_body = f"""\
Automated version bump from `{current_version}` to `{version}`.

**Before merging:**
- Check the [upstream release notes]({upstream_url}) for any new system dependencies or breaking changes.
- Confirm the test build below passes. If it fails, a new dependency likely needs to be added to the Dockerfile.

This PR was opened automatically by the update-check workflow.
"""

response = requests.post(
    f"https://api.github.com/repos/{repo}/pulls",
    json={
        "title": f"Bump version to {version}",
        "body": pr_body,
        "head": branch,
        "base": "master",
    },
    headers=api_headers,
    timeout=30,
)

if response.status_code == 201:
    print(f"PR opened: {response.json()['html_url']}")
else:
    print(f"Failed to create PR: {response.status_code} {response.text}")
    exit(1)
