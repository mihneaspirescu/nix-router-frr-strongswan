# Router lab: storage and cleanup

Snapshot: 2026-11-22. Sizes are what was on disk at that point.

> **Status (2026-11-22, later):** cleanup steps 1–5 done. The base image, VM disks, lab containers, switch image and builder cache are deleted, and the Mac Nix store is garbage-collected back to 485 MB (its pre-project size). Only source files and `lab/lab-key` remain. Rebuild with the command under "Rebuilding"; the first `nix develop` / `./deploy.sh` re-downloads QEMU and nixos-rebuild.

## What's using space

| What | Where | Size | Why it exists | Keep? |
|---|---|---|---|---|
| Base image | `out/router-base.raw` | 2.6 GB | The one image every router boots from | Yes, for more tests |
| VM disks | `lab/vms/site-{a,b}.qcow2` | 1.3 GB | Copy-on-write layers on top of the base image, one per running VM | While the lab runs |
| VM console logs and PID files | `lab/vms/*.console`, `*.pid` | KBs | Serial output and process IDs from `lab/vm.sh` | While the lab runs |
| Builder Nix store | Docker volume `router-nix-store` | 5.8 GB | Build cache for the base image (FRR, strongSwan, kernel…) | Yes, for faster rebuilds |
| Builder image | Docker `nixos/nix:latest` | 1.1 GB | Container that builds the base image | Yes, with the volume |
| LAN switch image | Docker `router-lab-switch:local` | 22 MB | Bridges Docker clients to the VMs' `lan` ports (`lab/lan/Dockerfile`) | While the lab runs |
| Lab containers | `site-{a,b}-lan`, `site-{a,b}-c{1,2}` | ~0 | Switches and test clients | While the lab runs |
| Mac Nix store | `/nix/store` | 3.5 GB (was 485 MB before this project) | Dev shell (QEMU, nixos-rebuild), nixpkgs source, build recipes from evaluating | Clears with a garbage collection, see below |

**Running processes:** 2 QEMU VMs (`site-a`, `site-b`, 1 GB RAM each) and 6 containers.

**Not ours, left alone:** `/tmp/nix-shell.jAJdoi` (Nov 21), the Docker volume `vscode`, and the other Docker images (SR Linux, SONiC, containerlab, `vrf-overlay-crypto`).

## Cleanup, in order

### 1. Stop the lab (keeps the base image)

```bash
lab/lan.sh down site-a; lab/lan.sh down site-b
lab/vm.sh destroy site-a; lab/vm.sh destroy site-b
```

`destroy` stops the VM and deletes its disk and console log. Use `lab/vm.sh stop <site>` to keep the disk.

### 2. Remove the switch image

```bash
docker rmi router-lab-switch:local
```

`lab/lan.sh up` rebuilds it automatically.

### 3. Remove the base image (when you're done testing)

```bash
rm -rf out
```

Rebuild it with the command under "Rebuilding" below.

### 4. Remove the builder cache (about 6.8 GB)

```bash
docker volume rm router-nix-store && docker rmi nixos/nix:latest
```

The next base-image build then downloads everything again, adding a couple of minutes.

### 5. Shrink the Mac Nix store

```bash
nix-collect-garbage
```

This also deletes **any other** unused paths in the Mac's store, not just this project's. Afterwards, the first `nix develop` or `./deploy.sh` downloads QEMU and nixos-rebuild again.

### 6. Final sweep

```bash
ls -d /tmp/nix-shell.* /tmp/nixos-rebuild.* 2>/dev/null   # nix develop leftovers; empty ones are safe to rmdir
docker ps -a --filter name=site-                         # should be empty after step 1
git status --short                                       # out/ and lab/vms/ are gitignored, so they never show here
```

## Rebuilding

```bash
docker run --rm --privileged -v router-nix-store:/nix -v "$PWD":/work -w /work \
  -e NIX_CONFIG=$'experimental-features = nix-command flakes\nsandbox = true' \
  nixos/nix:latest sh -c 'git config --global --add safe.directory /work &&
    nix build .#base-image --out-link /tmp/base && mkdir -p out && cp -L /tmp/base/*.raw out/'
```

Takes about 2 minutes with the builder cache, longer without it.

## Things to remember

- **Keep this folder a git repo.** Nix copies only tracked files into the store. Before `git init`, it copied the whole folder (3 GB image and VM disks included) on every evaluation, and the Mac's store grew to 55 GB. New files need `git add` before Nix can see them.
- **Pushes don't need the builder.** `./deploy.sh` evaluates on the Mac and the routers build their own systems. The builder volume and image only matter for rebuilding the base image.
- **Routers clean up after themselves.** Weekly garbage collection deletes generations older than 30 days, Nix collects automatically if free space drops below 1 GiB, and the boot menu keeps the last 5 generations. See `modules/base.nix`.
- **`lab/lab-key` is a lab-only private key** (gitignored). Delete it along with the lab. `keys/lab-admin.pub` is the matching public key baked into the image.
