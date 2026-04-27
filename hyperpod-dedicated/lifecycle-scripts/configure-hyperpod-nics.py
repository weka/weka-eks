#!/usr/bin/env python3
"""
configure-hyperpod-nics.py

Move NICs from the SageMaker HyperPod namespace into the host (default) namespace,
assign their AWS-assigned IPv4 addresses (from IMDS) with `noprefixroute`, and ensure
we don't accidentally change host routing (no default routes, no connected routes in main).

Selection modes:
1) Explicit interfaces:  --ifname <ifname> [--ifname <ifname> ...]
2) Count-based:          --count N        (auto-picks first N eligible NICs in netns)

Interface names follow AWS Nitro conventions (`enp*` for older udev names,
`ens*` for newer PCI-slot names — e.g. `ens65` on `ml.p4d.24xlarge`). The
count-based mode prefers DOWN interfaces, which on HyperPod corresponds to
the unconfigured secondary ENIs (the primary management NIC is UP with an
IP and is sorted last).

Outputs a JSON array of `[{mac_address, primary_ip, subnet_cidr_block}, ...]`
to /var/lib/weka/hyperpod-nics.json — read by the NIC annotator DaemonSet
and copied verbatim into the node's weka.io/weka-nics annotation, where the
WEKA operator unmarshals it as []domain.NIC.

The subnet CIDR is auto-detected from IMDS (primary ENI's subnet).
Override with --subnet-cidr if needed.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import subprocess
import sys
import time
from typing import List, Dict, Tuple


def sh(cmd: str, check: bool = True) -> subprocess.CompletedProcess:
    p = subprocess.run(
        ["bash", "-lc", cmd],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and p.returncode != 0:
        raise RuntimeError(
            f"Command failed ({p.returncode}): {cmd}\n"
            f"--- stdout ---\n{p.stdout}\n"
            f"--- stderr ---\n{p.stderr}\n"
        )
    return p


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr)


def require_root() -> None:
    if os.geteuid() != 0:
        raise SystemExit("ERROR: must run as root (use sudo)")


def normalize_mac(mac: str) -> str:
    return mac.strip().lower()


def imds_token(ttl_seconds: int = 21600) -> str:
    p = sh(
        "curl -sS -X PUT 'http://169.254.169.254/latest/api/token' "
        f"-H 'X-aws-ec2-metadata-token-ttl-seconds: {ttl_seconds}'"
    )
    tok = p.stdout.strip()
    if not tok:
        raise RuntimeError("Failed to obtain IMDSv2 token (empty response)")
    return tok


def imds_get(token: str, path: str) -> str:
    p = sh(
        "curl -sS "
        f"-H 'X-aws-ec2-metadata-token: {token}' "
        f"'http://169.254.169.254/latest/{path.lstrip('/')}'"
    )
    return p.stdout.strip()


def subnet_cidr_from_imds(token: str) -> str:
    mac = imds_get(token, "meta-data/mac").strip()
    if not mac:
        raise RuntimeError("IMDS returned no primary MAC")
    cidr = imds_get(token, f"meta-data/network/interfaces/macs/{mac}/subnet-ipv4-cidr-block").strip()
    if not cidr:
        raise RuntimeError(f"IMDS returned no subnet-ipv4-cidr-block for MAC {mac}")
    ipaddress.ip_network(cidr, strict=False)
    return cidr


def ip_from_imds_for_mac(token: str, mac: str) -> str:
    mac = normalize_mac(mac)
    out = imds_get(token, f"meta-data/network/interfaces/macs/{mac}/local-ipv4s")
    ip = out.splitlines()[0].strip() if out else ""
    if not ip:
        raise RuntimeError(f"IMDS returned no local-ipv4s for MAC {mac}")
    ipaddress.ip_address(ip)
    return ip


def iface_mac_in_netns(netns: str, ifname: str) -> str:
    p = sh(f"ip netns exec {netns} ip link show dev {ifname}")
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.startswith("link/ether"):
            parts = line.split()
            if len(parts) >= 2:
                return normalize_mac(parts[1])
    raise RuntimeError(f"Could not find MAC for {ifname} in netns {netns}")


def list_candidate_ifaces(netns: str, exclude: List[str]) -> List[Dict[str, str]]:
    """
    Returns ordered list (by ifindex) of candidate NICs in the given netns.
    We prefer interfaces that are DOWN (typical extra ENIs), but will still consider UP
    as long as they look like extra NICs.
    """
    # ip -o link gives stable ifindex ordering
    p = sh(f"ip netns exec {netns} ip -o link show")
    candidates: List[Dict[str, str]] = []

    for line in p.stdout.splitlines():
        # Example: "3: enp72s0: <BROADCAST,MULTICAST> mtu 9001 ... state DOWN ..."
        #          "35: veth_agent_def@if36: <...> ..."
        try:
            left, rest = line.split(":", 1)
            ifindex = int(left.strip())
        except Exception:
            continue

        rest = rest.strip()
        ifname = rest.split(":", 1)[0].strip()
        if "@" in ifname:
            ifname = ifname.split("@", 1)[0]

        # Basic filters
        if ifname in exclude:
            continue
        if ifname.startswith("lo") or ifname.startswith("veth") or ifname.startswith("eni"):
            continue
        # AWS Nitro / HyperPod NICs use enp* (older udev names) or ens*
        # (newer PCI-slot names, e.g. ens32 on p4d.24xlarge).
        if not (ifname.startswith("enp") or ifname.startswith("ens")):
            continue

        # Read state from this line (cheap parse)
        state = "UNKNOWN"
        if " state " in line:
            state = line.split(" state ", 1)[1].split()[0].strip()

        # Get MAC
        mac = iface_mac_in_netns(netns, ifname)

        candidates.append(
            {
                "ifindex": str(ifindex),
                "ifname": ifname,
                "state": state,
                "mac_address": mac,
            }
        )

    # Prefer DOWN first, then by ifindex
    def sort_key(x: Dict[str, str]) -> Tuple[int, int]:
        down_pref = 0 if x["state"] == "DOWN" else 1
        return (down_pref, int(x["ifindex"]))

    candidates.sort(key=sort_key)
    return candidates


def move_if_to_default(netns: str, ifname: str) -> None:
    # netns 1 is the host/default namespace on these nodes
    sh(f"ip netns exec {netns} ip link set {ifname} netns 1")


def bring_up(ifname: str) -> None:
    sh(f"ip link set dev {ifname} up")


def flush_addrs(ifname: str) -> None:
    sh(f"ip addr flush dev {ifname}")


def add_addr_noprefixroute(ifname: str, ip: str, prefix: int) -> None:
    sh(f"ip addr add {ip}/{prefix} dev {ifname} noprefixroute")


def cleanup_routes_in_main(ifname: str, subnet_cidr: str) -> None:
    # check=False already swallows the failure; no need for inner `|| true`.
    sh(f"ip route del {subnet_cidr} dev {ifname}", check=False)
    sh(f"ip route del default dev {ifname}", check=False)


def flush_route_cache_best_effort() -> None:
    sh("ip route flush cache", check=False)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()

    ap.add_argument(
        "--netns",
        default="sagemaker_agent_namespace",
        help="Netns that initially holds the extra NICs (default: sagemaker_agent_namespace)",
    )
    ap.add_argument(
        "--subnet-cidr",
        default=None,
        help="Subnet CIDR for these ENIs (used for annotation + route cleanup). Auto-detected from IMDS if omitted.",
    )

    sel = ap.add_mutually_exclusive_group(required=True)
    sel.add_argument(
        "--ifname",
        action="append",
        default=[],
        help="Interface name in the HyperPod netns to move (repeatable). Example: --ifname enp72s0",
    )
    sel.add_argument(
        "--count",
        type=int,
        help="Move the first N eligible NICs found in the HyperPod netns (prefers DOWN). Example: --count 2",
    )

    ap.add_argument(
        "--exclude-ifname",
        action="append",
        default=[],
        help="Interface names to exclude from auto-selection (repeatable).",
    )

    ap.add_argument(
        "--out",
        default="/var/lib/weka/hyperpod-nics.json",
        help="Where to write JSON output (default: /var/lib/weka/hyperpod-nics.json)",
    )
    ap.add_argument(
        "--no-move",
        action="store_true",
        help="Only resolve IFNAME/MAC/IP and emit JSON; do not move/configure NICs",
    )
    ap.add_argument(
        "--no-addr",
        action="store_true",
        help="Move NICs but do not assign IPv4 addresses (rarely useful)",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would happen; do not execute",
    )
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    require_root()

    log("Acquiring IMDSv2 token...")
    token = imds_token()

    if args.subnet_cidr:
        subnet_cidr = args.subnet_cidr
    else:
        log("Resolving subnet CIDR from IMDS...")
        subnet_cidr = subnet_cidr_from_imds(token)
        log(f"  subnet_cidr = {subnet_cidr}")

    subnet = ipaddress.ip_network(subnet_cidr, strict=False)
    prefix = int(subnet.prefixlen)

    # Determine which interfaces to operate on
    ifnames: List[str] = []
    if args.ifname:
        ifnames = list(args.ifname)
    else:
        # args.count is guaranteed to be set here by the argparse mutex group.
        if args.count <= 0:
            raise SystemExit("ERROR: --count must be > 0")

        log(f"Auto-selecting {args.count} NIC(s) from netns {args.netns} (excluding: {args.exclude_ifname})...")
        candidates = list_candidate_ifaces(args.netns, exclude=args.exclude_ifname)

        if len(candidates) < args.count:
            msg = (
                f"ERROR: requested --count {args.count} but only found {len(candidates)} eligible NIC(s).\n"
                f"Candidates found:\n" + "\n".join(
                    f"  {c['ifname']} state={c['state']} mac={c['mac_address']}" for c in candidates
                )
            )
            raise SystemExit(msg)

        chosen = candidates[: args.count]
        ifnames = [c["ifname"] for c in chosen]

        log("Chosen NICs:")
        for c in chosen:
            log(f"  {c['ifname']} state={c['state']} mac={c['mac_address']}")

    # Resolve (ifname -> mac -> ip)
    nics: List[Dict[str, str]] = []
    for ifname in ifnames:
        mac = iface_mac_in_netns(args.netns, ifname)
        ip = ip_from_imds_for_mac(token, mac)
        nics.append(
            {
                "ifname": ifname,
                "mac_address": mac,
                "primary_ip": ip,
                "subnet_cidr_block": str(subnet),
            }
        )

    out_obj = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "netns_source": args.netns,
        "subnet_cidr_block": str(subnet),
        "prefix": prefix,
        "nics": nics,
    }

    log("Resolved NICs (for annotation):")
    for n in nics:
        log(f"  {n['ifname']}: mac={n['mac_address']} ip={n['primary_ip']} cidr={n['subnet_cidr_block']}")

    if args.dry_run:
        print(json.dumps(out_obj, indent=2))
        log("Dry-run: not writing file or changing NICs.")
        return 0

    # Write JSON early (useful even if later steps fail).
    # The file is consumed by the NIC annotator DaemonSet, which copies its
    # contents verbatim into the node's weka.io/weka-nics annotation. The
    # WEKA operator unmarshals that annotation as []domain.NIC — a bare
    # array of {mac_address, primary_ip, subnet_cidr_block}. So the file
    # must contain the array, not the wrapper. The wrapper (out_obj) is
    # still printed to stdout/stderr for human-readable diagnostics.
    out_path = args.out
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(nics, f, indent=2)
        f.write("\n")
    log(f"Wrote NIC info JSON: {out_path}")

    if args.no_move:
        log("--no-move set: done.")
        print(json.dumps(out_obj, indent=2))
        return 0

    # Move + configure each NIC
    for n in nics:
        ifname = n["ifname"]
        ip = n["primary_ip"]

        log(f"Moving {ifname} from netns {args.netns} -> default...")
        move_if_to_default(args.netns, ifname)

        log(f"Bringing {ifname} up...")
        bring_up(ifname)

        if not args.no_addr:
            log(f"Assigning {ip}/{prefix} to {ifname} with noprefixroute (no connected route in main)...")
            flush_addrs(ifname)
            add_addr_noprefixroute(ifname, ip, prefix)

        log(f"Cleaning up any accidental routes in main via {ifname} (best-effort)...")
        cleanup_routes_in_main(ifname, str(subnet))

    flush_route_cache_best_effort()

    # Non-fatal sanity
    log("Post-state summary (non-fatal):")
    sh("ip -br addr | grep -E '^(lo|en[ps])'", check=False)
    sh(f"ip route show {subnet}", check=False)
    sh("ip route show default", check=False)

    print(json.dumps(out_obj, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log(f"ERROR: {e}")
        sys.exit(1)

