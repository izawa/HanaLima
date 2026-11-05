# lima-driver-spike

Superseded by `Driver/` (the real driver, stage 1 of docs/09); kept as the stage-0 record.

A Swift stub of a Lima external VM driver (`lima-driver-hanalima`), from the stage-0 work in
docs/09. It speaks Lima 2.2.1's `driver.proto` over a Unix socket with grpc-swift 2 and does
nothing else: every RPC is logged to stderr and answered with a plausible stub, so `limactl
create --vm-type=hanalima`, `limactl list` and `limactl delete` work against it. It does not
boot anything (Start just streams a success and waits for Stop).

Scaffolding written by Codex, then fixed by hand:

- `Package.swift`: grpc-swift-2 / grpc-swift-nio-transport 2.x / grpc-swift-protobuf 2.x must
  be from the same line (mixing `grpc-swift` 2.0.0 and `grpc-swift-2` duplicates targets).
- `grpc-swift-proto-generator-config.json`: `protoc.executablePath` points at Homebrew's protoc.
- `AcceptErrorFilter` (Main.swift): Lima probes the socket by connecting and closing at once;
  on Darwin that makes NIO's accept throw `NIOFcntlFailedError`, which ends the transport's
  accept loop and the server. A handler on the listening channel swallows that error.
- `Configure` (DriverService.swift) fills what Lima expects the driver to fill (`mountType`,
  `ssh.overVsock`, `vmOpts.vz`), or `limayaml.Validate` dereferences nil and `limactl` panics.
  It also sets `dns: [192.168.5.2]` and `hostResolver.enabled: false`, because cidata gives
  non-"vz" drivers QEMU's 192.168.5.3 as DNS, which gvisor's usernet does not serve.

Build and try:

```bash
swift build
mkdir -p /tmp/drv && cp .build/debug/lima-driver-hanalima /tmp/drv/
LIMA_DRIVERS_PATH=/tmp/drv limactl info | jq .vmTypes
LIMA_DRIVERS_PATH=/tmp/drv limactl create --vm-type=hanalima --name hanalima-e2e-stub template:alpine
LIMA_DRIVERS_PATH=/tmp/drv limactl list
LIMA_DRIVERS_PATH=/tmp/drv limactl delete --force hanalima-e2e-stub
```
