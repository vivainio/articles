# A Shared EC2 Dev Box for Coding Agents

*2026-09-17*

Coding agents do not need GPUs. Claude Code, Codex, and similar tools send the
model work to an API; the machine under your control runs the repository,
shell commands, builds, tests, and containers. That makes a shared EC2 instance
a plausible alternative to maintaining a complete development environment on
every laptop.

The appealing version is simple: several people connect from Windows laptops,
each gets an isolated Linux account, and the server stays unreachable from the
public internet while retaining outbound access. The details matter, though.
Identity, Git ownership, container isolation, and port allocation all become
shared-host problems.

## The shape of the system

I would start with this:

- one Ubuntu EC2 instance with an EBS-backed root or data volume
- no inbound security-group rules
- access through AWS Systems Manager Session Manager
- one Unix account and home directory per person
- one shared bare Git repository with a separate worktree per person or task
- rootless Podman for disposable services and build environments
- `tmux` or [Herdr](../terminal/herdr.md) for sessions that survive disconnects

The instance needs outbound HTTPS for agent APIs, Git hosting, package
registries, operating-system updates, and AWS services. It does not need an
inbound SSH port just because users need a shell. Session Manager establishes
the management connection through the SSM agent's outbound traffic.

A public subnet with no inbound rules is the cheapest simple layout. A private
subnet with NAT also works, but a NAT Gateway can become an unexpectedly large
fixed cost for a small development box. VPC endpoints can remove some NAT
traffic, but they do not replace general internet access to GitHub, Anthropic,
OpenAI, npm, PyPI, and similar services.

The calculation changes when a dynamic set of development machines in the same
VPC must reach services that allowlist source IPv4 addresses. The simplest
managed option is to put the machines in private subnets and route their
internet-bound traffic through a public NAT Gateway with an Elastic IP. The
external services then see one stable address for the fleet, while instances
can be added, replaced, or removed without changing the allowlist and still
accept no internet-initiated traffic.

This simplicity has a material cost: AWS charges for each NAT Gateway hour and
for every gigabyte it processes, in addition to public IPv4 and normal data
transfer charges. In `eu-west-1`, one continuously provisioned gateway and its
public IPv4 address are on the order of $40 per month before traffic, plus
roughly five cents per gigabyte processed; check current
[VPC pricing](https://aws.amazon.com/vpc/pricing/) before provisioning.

For disposable development machines, one NAT Gateway is a reasonable choice:
it keeps the allowlist to one address, and loss of internet access during an
Availability Zone failure is usually acceptable. Instances in other zones may
also incur cross-zone traffic charges. A gateway in every Availability Zone
would improve availability but multiply the fixed cost and the number of
addresses to allowlist. A self-managed NAT instance can cost less at low traffic
volumes, but gives the team responsibility for patching, capacity, monitoring,
and failover.

## Size for builds, not inference

The coding agent process is rarely the capacity problem. Test suites,
compilers, language servers, package installations, and containers are.

For a small group, I would begin around four vCPUs and 16 GiB of memory, then
measure. Burstable instances can be economical for genuinely intermittent
use, but sustained concurrent builds consume CPU credits. A general-purpose
instance is easier to reason about once the machine is busy for much of the
day.

## Put home directories on the large volume

Disk demand does not live only in the shared repository. Rootless container
images and volumes, dependency caches, SDKs, language servers, personal clones,
agent state, and build outputs normally accumulate under each user's home
directory. A large data volume must therefore cover `/home` as well as shared
paths under `/srv`.

A practical starting layout is a 50--100 GiB root volume for Ubuntu and shared
tools plus a 1--2 TiB gp3 EBS data volume. Mount the data volume at `/data` and
bind-mount directories from it onto `/home`, `/srv/git`, and `/srv/worktrees`,
or use separate data volumes when those paths need different backup or lifecycle
policies. One filesystem pools free space more efficiently, but user quotas and
alerts are important so one container image store or build cache cannot fill it
for everyone.

EBS volumes can normally be enlarged online, after which the partition and
filesystem must also be extended. They cannot be shrunk in place. At the time
of writing, gp3 storage in `eu-west-1` is roughly $90 per TiB-month, so 2 TiB is
about $180 per month before snapshots or any extra provisioned performance.
Check current [EBS pricing](https://aws.amazon.com/ebs/pricing/) and alert at
several thresholds before the filesystem is full.

EFS is useful when several instances must mount the same files or when instances
are meant to be disposable. It is otherwise extra cost and network-filesystem
latency in a workload that walks many small files. Stopping an instance for a
weekend does not require EFS: AWS preserves attached EBS volumes across a normal
stop/start cycle, although storage charges continue. Encrypt the data volume
and its snapshots and restrict snapshot access because they contain every
user's credentials and agent state. Instance-store data and an automatically
assigned public IPv4 address do not survive a stop/start cycle. See AWS's
[EC2 stop/start behavior](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-stop-start-works.html).

## Give every person a real Unix identity

Create separate accounts instead of letting everybody work as `ssm-user`:

```bash
sudo adduser alice
sudo adduser bob
```

Home-directory permissions then separate Git credentials, agent settings,
shell history, package caches, and API credentials. Do not place secrets in a
shared shell profile. Prefer each tool's login flow or a secrets service, and
grant `sudo` only where it is actually needed.

Developers can still use the AWS CLI to access other AWS accounts through IAM
Identity Center. Each Unix user keeps their own AWS profiles and cached SSO
session in their home directory, runs `aws sso login`, and selects the intended
account and role with an explicit `--profile`. This access is independent of
the EC2 instance role, which remains available to commands that do not select
another credential source.

Session Manager can start a session as a named OS user. Enable **Run As** in
Session Manager preferences, create the corresponding account on the instance,
and tag each IAM user or role with `SSMSessionRunAs=<username>`. AWS checks the
IAM session tag first, then the role tag, then the configured default user.

That tag is close to unusable once federated access through IAM Identity
Center (AWS SSO) is in the picture, which it typically is for a shared team
account. Everyone who assumes a given permission set shares the same IAM
role, so `aws iam tag-role` on it sets one Unix user for every person who
federates in through it -- it maps a role, not a person. Getting a distinct
Unix user per person would mean attaching session tags at assume-role time
through IAM Identity Center attribute mappings (ABAC), pulling something like
an email or username attribute from the identity source into a session tag on
federation -- a real Identity Center configuration project, not a single CLI
call. `sudo -iu <user>` sidesteps all of it: no IAM or Identity Center changes,
just the Unix account.

There is an important scope detail: IAM tags let different identities map to
different Unix users, but enabling Run As is still a Session Manager preference
for the AWS account and Region. Editing an agent JSON file on one instance is
not an instance-local substitute. If that scope is unacceptable, keep the
default SSM login and use tightly controlled `sudo -iu <user>`, or provision a
separate account or Region boundary. AWS documents the exact behavior in
[Turn on Run As support](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html).

The mapped username also has to exist as a real account on whatever instance
the session lands on. When it does not, Session Manager fails the session
instead of quietly falling back to a default user; the `sudo -iu <user>`
substitute fails the same way, with `sudo: unknown user <name>` and a nonzero
exit. That is a safe failure, but it means the account/Region-wide preference
carries an implicit account/Region-wide obligation: every instance a mapped
identity might connect to needs the same username provisioned on it, or their
session breaks there. That is easy to guarantee on an AWS account dedicated to
this one shared-dev-box purpose, where accounts are provisioned uniformly
across a small, known set of instances. It is much harder to guarantee on a
general-purpose or multi-team sandbox account where instances accumulate
different user sets independently over time -- which is itself a reason to
prefer `sudo -iu <user>` there instead of touching the shared preference.

EC2 Instance Connect, and its VPC-scoped Instance Connect Endpoint variant,
offer a similar SSH path that also avoids inbound security-group rules -- the
endpoint only needs to be reachable from its own security group, not the
internet -- and it runs into the identical shared-role problem. Restricting
which OS user a principal may push a key for is done through an IAM condition
on `ec2-instance-connect:SendSSHPublicKey`; AWS's example policies use a key
named `ec2:osuser` for exactly this. A naive policy per person still means one
IAM statement, or one role, per person, which is the wrong shape under a
shared IAM Identity Center permission set.

The fix is the same fix: attribute-based access control, with one statement
attached once to the shared role instead of one per person --

```json
{
  "Effect": "Allow",
  "Action": "ec2-instance-connect:SendSSHPublicKey",
  "Resource": "arn:aws:ec2:region:account:instance/i-0123456789abcdef0",
  "Condition": {
    "StringEquals": { "ec2:osuser": "${aws:PrincipalTag/UnixUser}" }
  }
}
```

The policy variable `${aws:PrincipalTag/UnixUser}` resolves to a different
value per session, so the same statement enforces a different Unix username
for every person, provided a `UnixUser` session tag is actually present on
their session. That tag still has to come from somewhere: an IAM Identity
Center attribute mapping that injects it from the identity source at
federation time -- the same one-time ABAC project noted above for Run As, not
a per-person role. It has one advantage over Run As: the condition is scoped
to whichever instance `Resource` ARN the statement names, so it does not
carry Run As's account/Region-wide blast radius.

(!) `ec2:osuser` could not be confirmed against AWS's current documentation
while writing this -- the docs site did not render for automated fetches
during that check, and IAM's policy simulator cannot distinguish a real,
service-populated condition key from a fabricated one, so testing a
made-up key alongside it produced identical results. Treat this as a
pattern to verify against a real, narrowly-scoped test role before relying
on it, not a confirmed control.

## Share a repository, not a working tree

A shared repository from which users create separate worktrees is a good
default for a trusted team. It gives everyone one object database and one set
of fetched refs, while each person or agent gets an independent checkout.

Two agents in one working tree can overwrite files, disagree about the index,
and contend on lock files. Separate worktrees avoid those problems because
every worktree has its own index and files.

A practical layout is:

```text
/srv/git/project.git                 shared bare repository and object store
/srv/worktrees/alice/feature-a      owned and used by alice
/srv/worktrees/bob/bug-b            owned and used by bob
```

Initialize the shared repository for group access and put the trusted users in
the same Unix group:

```bash
sudo install -d -o root -g dev-shared -m 2775 /srv/git /srv/worktrees
git clone --bare --shared=group git@github.com:example/project.git \
  /srv/git/project.git
```

Each user can then create a worktree for a branch that no other worktree has
checked out:

```bash
mkdir -p /srv/worktrees/$USER
git --git-dir=/srv/git/project.git worktree add \
  /srv/worktrees/$USER/feature-a -b "$USER/feature-a" origin/main
```

The shared directory needs SGID permissions and users should use a cooperative
umask such as `0002`, otherwise one user can create repository metadata that the
next user cannot update. Add the exact shared repository to each trusted user's
`safe.directory` configuration if Git's ownership check requires it; avoid a
blanket `safe.directory=*` exception.

This model does introduce a deliberate trust boundary. Git configuration,
hooks, refs, objects, worktree registration, fetches, and maintenance all touch
the common repository. Every member who can write there can affect every other
member. Use it for a trusted team on one host, not as isolation between mutually
untrusted users. It is also worth wrapping worktree creation and removal in a
small script so naming, ownership, branch namespaces, and cleanup remain
consistent.

The useful choices are therefore:

1. Give each user a clone in their own home directory and collaborate through
   the normal remote repository when users should not trust one another.
2. Let a trusted group share a bare repository and create a separately owned
   worktree per person or task.
3. Keep a local bare mirror as a read-only clone source when object sharing is
   useful but a shared writable Git database is not.

Git itself says it works best through `push` and `fetch` and is not designed to
share one working tree across untrusted users. Its [Git FAQ](https://git-scm.com/docs/gitfaq#sync-working-tree)
is a useful warning against turning a checkout into a network share; it does
not rule out distinct linked worktrees backed by a shared repository among
trusted users.

This also answers the Windows file-sharing question: avoid Samba for live
repositories. Work through a remote terminal, use an editor over an SSM-backed
SSH connection if desired, and move deliberate artifacts with Git, S3, or an
explicit copy operation. The files remain on the server instead of being
continuously synchronized underneath Git.

## Rootless Podman fits the account model

Rootless Podman gives every Unix user a separate container view, image store,
and volume store without putting them in a root-equivalent Docker group.
Verify that each user has subordinate UID and GID ranges:

```bash
grep '^alice:' /etc/subuid /etc/subgid
```

Podman's [rootless-mode documentation](https://docs.podman.io/en/stable/markdown/podman.1.html#rootless-mode)
describes the required mappings. Modern Ubuntu releases use cgroup v2, which
also makes per-user resource control practical.

Rootless containers improve isolation, but they do not create capacity. Put
CPU and memory limits on workloads so one runaway test suite cannot make every
interactive session miserable. Enable systemd user lingering only for users
whose background services should survive logout:

```bash
sudo loginctl enable-linger alice
```

## Let the machine choose preview ports

Several users cannot all publish a service on host port 8080. For temporary
previews, let Podman allocate a free host port:

```bash
podman run --rm -d -p 127.0.0.1::8080 my-web-app
podman port --latest 8080
```

Binding to `127.0.0.1` keeps the preview off the instance's network interfaces.
Reach it through an SSM port-forwarding session. This is cleaner than opening a
security-group rule for every preview and safer than publishing on all
interfaces.

For example, suppose Alice starts a web application that listens on port 8080
inside its container:

```bash
$ podman run --rm -d --name alice-preview \
    -p 127.0.0.1::8080 my-web-app
$ podman port alice-preview 8080
127.0.0.1:32815
```

Podman selected host port `32815`. On her Windows laptop, Alice starts a
Session Manager tunnel to that port from WSL:

```bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=["32815"],localPortNumber=["8080"]'
```

She can now open [http://localhost:8080](http://localhost:8080) in her Windows
browser. Requests to that local port travel through Session Manager to
`127.0.0.1:32815` on the instance and then into the container. The EC2 instance
needs no public IP, inbound security-group rule, or listening network port for
the preview.

The laptop needs the AWS CLI and Session Manager plugin, and Alice's IAM
identity needs permission to start a session on the instance. The command stays
open for the lifetime of the tunnel; stopping it removes local access without
changing the server or its firewall.

Stable shared services need a different arrangement: assign explicit ports
from documented per-user ranges, or put an authenticated reverse proxy in
front. Dynamic ports are excellent for short-lived agent work; they are not a
service-discovery system.

## What I would automate

The value of the shared server depends on making it reproducible. I would keep
the following in infrastructure and configuration code:

- instance, EBS volume, IAM instance role, and security group
- SSM connectivity and narrowly scoped user access
- Unix accounts, subordinate UID/GID ranges, and resource limits
- Podman, Git, agent CLIs, tmux, and Herdr installation
- scheduled stop/start behavior, backups, and EBS snapshot policy
- disk, memory, CPU, and failed SSM-session monitoring

Dotfiles and personal agent configuration should remain user-owned and roam
through a private dotfiles repository or a tool such as chezmoi. Shared base
packages belong in machine provisioning; personal credentials do not.

## Other things worth sharing

A multi-user machine also creates some optional consolidation opportunities:

- dependency, compiler, and build caches for tools such as npm, Maven, Gradle,
  Cargo, `ccache`, and `sccache`
- a pull-through container registry cache for commonly used base images
- long-lived development services such as PostgreSQL, Redis, Kafka, or
  LocalStack, with separate databases, namespaces, and credentials per user
- artifact storage for test reports, installers, database snapshots, and other
  large outputs that do not belong in Git
- shared monitoring for disk pressure, resource contention, container logs,
  and preview-service health
- scheduled cache warming, image pulls, repository fetches, snapshots, and
  shutdown of idle services

These are possibilities rather than requirements. They add operational state
and are worthwhile only when repeated downloads, builds, or duplicate services
are a measurable cost. A useful boundary is to share expensive immutable inputs
and deliberately managed services while keeping credentials, working trees,
agent history, and disposable experiments per user. Avoid shared writable
package environments, root-equivalent container sockets, and databases without
clear per-user isolation.

## When consolidation stops paying

One shared host saves money when users are intermittent and their peaks rarely
overlap. It also reduces duplicated storage and maintenance. The trade-off is a
larger blast radius: a broken host, full disk, exhausted memory pool, or careless
administrator affects everyone.

Start consolidated, observe the real workload, and keep the boundary movable.
Separate Unix accounts, independent checkouts, rootless containers, and
declarative provisioning make it possible to move a heavy user or project onto
its own instance later. That is the useful version of a shared coding-agent
server: pooled infrastructure without pooled ownership of the work itself.
