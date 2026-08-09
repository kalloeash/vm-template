# Delivery models

How the hardening reaches a machine. This matters as much as the modules: research on
server templating is consistent that **an unhardened base image applied later is security
debt** — the window between first boot and "hardened" is exposure. So the same modules
support three entry paths, cheapest-to-adopt first, most-mature last.

## A — post-boot (day-0 on an existing box)

```bash
git clone <repo> && cd vm-template && sudo make harden
```

The path the original manual process uses today. Right for a box that already exists, or a
first run you want to watch. Honest downside: there is a window between boot and `make
harden` where the machine runs with provider defaults (often password SSH on). Mitigate by
running it as the very first action, before opening the app ports.

## B — cloud-init first boot (recommended for new VMs)

Provision the modules from `user-data` so hardening finishes **before the machine is
reachable for its real purpose**. Skeleton in [examples/cloud-init.yaml](../examples/cloud-init.yaml):

```yaml
#cloud-config
package_update: true
runcmd:
  - [git, clone, "<repo>", /opt/vm-template]
  - [bash, -c, "cd /opt/vm-template && make harden ADMIN_USER=admin"]
```

Cloud-init already injects the admin SSH key and can set `ssh_pwauth: false` on the first
boot, which closes the day-0 window that path A leaves open. Never put secrets in
`user-data` — it is readable via the instance metadata service. This is the sweet spot for
a single VPS: no build pipeline, but hardened from first boot.

## C — Packer golden image (the scale-up endgame)

Bake the hardened state into a versioned image once; launch instances that are already
compliant. Removes configuration drift entirely (you rebuild rather than patch in place),
gives an auditable build with a version stamp, and means production runs exactly what was
reviewed. Overkill for one VPS — the value appears when there is more than one instance or
a compliance story to tell. Not built yet; tracked as a roadmap ticket. The modules are
written to run unmodified inside a Packer `shell` provisioner, so adopting Packer later is
additive, not a rewrite.

## Choosing

| Situation | Path |
|---|---|
| Existing box, or first supervised run | A (post-boot) |
| New single VPS from a cloud image | **B (cloud-init)** |
| More than one instance, or need an audit trail of images | C (Packer) |

The module code is identical across all three — only the invocation differs. That is the
design constraint: nothing in a module may assume it runs interactively or post-boot.
