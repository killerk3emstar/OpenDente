# Add a native macOS charge-limit fallback

> Date: 2026-11-10
> Status: verified
> Change type: fix
> Scope: charging control, privileged helper, charging settings

## Outcome

An M1 Pro running macOS 27.0.1 exposes neither readable `CHTE` nor `CH0B`
charging keys. The app and root helper previously reported an unknown charging
API. PowerUI's manual charge-limit service is available on this configuration
and advertises 80, 85, 90, 95, and 100 percent targets.

OpenDente now falls back to that service when direct SMC control is unavailable.
Existing SMC backends remain first choice. Native mode rejects unsupported
targets and disables advanced controls it cannot implement. A 100 percent
request disables the native limit; macOS may drain toward a lower target or
temporarily override it for battery calibration.

## Implementation

- [PowerUI bridge](../../../Shared/PowerUIBridge.m): runtime discovery, advertised
  targets, state reading, limit requests, and restoration. No writes to protected
  SMC keys or powerd policy archives.
- [Native session](../../../Shared/NativeChargeSession.swift): atomically saves
  the original setting before mutation; validates recovery data; retains it on
  restoration failure. The helper serializes requests and uses a root-only
  state directory.
- [Helper](../../../OpenDenteHelper/HelperDelegate.swift): version 1.4.0, native
  XPC request, startup/disconnect/watchdog recovery.
- [Charging manager](../../../OpenDente/Services/ChargingManager.swift): applies
  native limits independently of plug state, gates the new request on helper
  version, handles Top Up, and reports request errors.
- Reinstall Helper refreshes SMAppService registration after changing a locally
  signed build. Merely toggling a stale registration was insufficient in testing.

## Verification

- Release build and strict recursive code-signature verification passed.
- 288 unit tests passed, including 15 native backend/policy/state-machine tests.
- The root helper detected native mode, accepted 80 percent, and the app reached
  Charge Limit Reached with AC connected.
- Independent `pmset -g battlimit` output showed active, nonterminated
  `manualChargeLimit` registrations at 80 percent. PowerUIAgent reported
  DischargingToMCL after a request.
- Terminating the app restored the previous disabled/100 percent setting;
  `pmset -g battlimit` returned no limits.
- Relaunching the final installed Release build connected to helper 1.4.0 and
  re-registered the 80 percent policy.
- IORegistry then reported AC connected, charging false, and battery current
  negative (discharging toward the target), independently of the app's mode label.

## Limitations

Only the M1 Pro/macOS 27.0.1 configuration was exercised. A complete discharge
from 100 to 80 percent and overnight sleep/wake behavior were not observed.
PowerUI is a private interface and may change. API acceptance is verified by
readback, but it does not prove that a firmware charging transition completed.
Existing helper caller-authentication weaknesses are unchanged by this patch
and require a separate security fix before broader distribution.

The bridge was independently implemented after investigating the public
[batt PowerUI backend](https://github.com/charlie0129/batt/tree/main/pkg/powerui)
and [Ampere native-limit description](https://github.com/az-code-lab/ampere/blob/main/Sources/Shared/NativeChargeLimit.swift).
