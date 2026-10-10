# Apple Feedback: vmnet の bridge100 衝突（FB25122122）

**送信済み: FB25122122**（2026-10-09 20:35、個人用、Developer Technologies & SDKs → macOS → Virtualization Framework）。sysdiagnose と再現ツール一式（zip）を添付。

以下は送信した内容の控えです。2026-10-09 に再現手順を実行し、結果を反映しています。

## Feedback Assistant の入力項目

- **プラットフォーム**: macOS
- **領域（Area）**: 「Virtualization」が選べればそれ、なければ「Networking」
- **種類**: Incorrect/Unexpected Behavior
- **再現性**: Always（下記手順で毎回）
- **添付**:
  - `Prototypes/vmnet-bridge100-repro/repro.swift` と `entitlements.plist`
  - `Prototypes/vmnet-bridge100-repro/results-2026-10-09/step7a`〜`step7e` の `*-bridges.txt` / `*-en0.txt`（各手順の ifconfig 出力。step3〜6 は対照実験）
  - sysdiagnose: `/private/var/tmp/sysdiagnose_2026.10.09_20-11-54+0900_macOS_Mac_26A434.tar.gz`（手順 4 の直後、en0 の IPv4 が消えた状態で取得）

以下の英語部分（Title 以降）を各欄にコピーしてください。

---

## Title

vmnet: restarting an interface on an existing vmnet_network takes over a legacy bridged interface's bridge100, detaching en0 and removing the host's IPv4 address

## Description

A vmnet_network (macOS 26 API: `vmnet_network_create` + `vmnet_interface_start_with_network`, VMNET_SHARED_MODE, custom subnet) remembers the bridge unit it got at its first activation. After its interface is stopped (the bridge is torn down) and a legacy bridged interface (`vmnet_start_interface`, VMNET_BRIDGED_MODE on en0, as used by socket_vmnet and Lima) is started and gets the same unit, starting an interface on the vmnet_network again reuses that unit: bridge100 is reconfigured with the vmnet_network's address, the bridged interface's vmenet and en0 are removed from it, and the host's en0 loses its IPv4 address. The bridged guest loses connectivity, and the host keeps only IPv6 until DHCP is re-run on en0.

Both APIs work correctly on their own, and also together when both are freshly activated, in either order (they get bridge100 and bridge101). The problem only appears when a vmnet_network object is reused after its interface was stopped, which is what a long-lived helper that serves VMs over time does. This looks like the bridge-unit reuse described in apple/container#2051, here colliding with the legacy bridged mode.

Related: apple/container#2051; FB24895271 and https://developer.apple.com/forums/thread/847642 (an idle vmnet_network also drops its DHCP reservations).

## Steps to Reproduce

1. Build the attached tool and sign it with the attached entitlements (com.apple.security.virtualization):
   `swiftc -O -o repro repro.swift && codesign -s - -f --entitlements entitlements.plist repro`
2. Make sure no bridge1xx exists: `ifconfig | grep ^bridge1`
3. Terminal A: `./repro network-cycle 192.168.242.1` (creates a vmnet_network and starts an interface)
4. Terminal A: press Enter (stops the interface; the vmnet_network object is kept)
5. Terminal B: `./repro bridged en0` (legacy bridged interface on en0)
6. Terminal A: press Enter (starts an interface again on the same vmnet_network object)
7. Run `ifconfig | grep -A12 '^bridge1'; ifconfig en0 | grep 'inet '` after each step.

## Expected Results

After step 6, the vmnet_network gets a free bridge (e.g. bridge101). The bridged interface stays on its bridge together with en0, and en0 keeps its IPv4 address.

## Actual Results

- After step 3: bridge100 = 192.168.242.1, member vmenet0. en0 = 192.168.100.4.
- After step 4: no bridge1xx. en0 = 192.168.100.4.
- After step 5: bridge100 (no address), members vmenet0 (legacy bridged) and en0. en0 = 192.168.100.4.
- After step 6: bridge100 = 192.168.242.1, member vmenet1 only. The legacy bridged vmenet0 and en0 are no longer members of any bridge, and **en0 has no IPv4 address** (IPv6 only). Both calls returned VMNET_SUCCESS (1000), with no error reported to either process.
- After stopping both processes (Ctrl-C, interfaces stopped with `vmnet_stop_interface`): no bridge1xx, and en0 still has no IPv4 address. `sudo ipconfig set en0 DHCP` restores it.

Control (works as expected): with fresh objects, `./repro network ...` then `./repro bridged en0` gives bridge100 = vmnet_network and bridge101 = bridged + en0; the reverse order gives bridge100 = bridged + en0 and bridge101 = vmnet_network. en0 keeps its IPv4 address in both cases.

Originally hit with Lima 2.2.1 VMs (Virtualization.framework): a helper process kept a vmnet_network for one VM's NIC while socket_vmnet provided a bridged NIC on en0; restarting the VM led to the same takeover of bridge100 and loss of the host's IPv4 address. In another order, a vmnet_network created before the bridged interface existed later failed `vmnet_interface_start_with_network` with VMNET_FAILURE (1001).

Additional observation: a process that exits while a `vmnet_interface_start_with_network` interface is still started (e.g. killed, or `exit()` from a signal handler) leaves the subnet reserved. `vmnet_network_create` then fails with VMNET_FAILURE (1001) for that subnet in any process until the Mac restarts. Stopping the interface before exiting avoids it.

## Configuration

- macOS 27.0.1 (26A434), Mac mini (Mac16,11), wired Ethernet on en0
- Xcode 27.0 (27A266a)
- Repro signed ad hoc with com.apple.security.virtualization; both modes run without root in this configuration
