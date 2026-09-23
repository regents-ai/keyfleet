# Vendored Chainlink VRF v2.5 files

These three files are copied byte for byte from
[smartcontractkit/chainlink-evm](https://github.com/smartcontractkit/chainlink-evm)
at commit `b6cf3a6ff90c7172e1d6090d056c0f77282450ce`. They are not edited. Their
upstream folder layout (`libraries/`, `interfaces/`) is kept so that their own
relative imports resolve without a remapping.

| File here | Upstream path | SHA-256 |
| --- | --- | --- |
| `libraries/VRFV2PlusClient.sol` | [`contracts/src/v0.8/vrf/libraries/VRFV2PlusClient.sol`](https://raw.githubusercontent.com/smartcontractkit/chainlink-evm/b6cf3a6ff90c7172e1d6090d056c0f77282450ce/contracts/src/v0.8/vrf/libraries/VRFV2PlusClient.sol) | `f3b89bb466c2a79b10c1816d342fbfbec49fe82695cba92bd46e7d31af698011` |
| `interfaces/IVRFCoordinatorV2Plus.sol` | [`contracts/src/v0.8/vrf/interfaces/IVRFCoordinatorV2Plus.sol`](https://raw.githubusercontent.com/smartcontractkit/chainlink-evm/b6cf3a6ff90c7172e1d6090d056c0f77282450ce/contracts/src/v0.8/vrf/interfaces/IVRFCoordinatorV2Plus.sol) | `b09dc6442316ff371ed04bd1c36a877a071e10d76d0270b6b7a732b38a9114cc` |
| `interfaces/IVRFSubscriptionV2Plus.sol` | [`contracts/src/v0.8/vrf/interfaces/IVRFSubscriptionV2Plus.sol`](https://raw.githubusercontent.com/smartcontractkit/chainlink-evm/b6cf3a6ff90c7172e1d6090d056c0f77282450ce/contracts/src/v0.8/vrf/interfaces/IVRFSubscriptionV2Plus.sol) | `a2ca681d739ab906c2bb659ed4ce032fd5b2982155bb787f36a45050e81e3d39` |

`IVRFCoordinatorV2Plus.sol` imports the other two, which is why both are here.
Nothing else is imported.

Each file carries an `SPDX-License-Identifier: MIT` header. `LICENSE` next to
this file is the first 23 lines of the upstream repository's
[`LICENSE`](https://raw.githubusercontent.com/smartcontractkit/chainlink-evm/b6cf3a6ff90c7172e1d6090d056c0f77282450ce/LICENSE)
at the same commit, byte for byte: the copyright line and the MIT License text
that covers these files. The rest of the upstream file licenses
`./pkg/bindings/abigen` under the LGPL, and nothing here comes from there. The
whole upstream file has SHA-256
`25a502f8fd39602de8a98cc4835a4bf81851b095d6f2c5c130bf0863afac6c99`; `LICENSE`
here has SHA-256
`cea88371fd9aaea4232aeffb23be3f28680304693f454108850ebdc79406ce11`. The package
is not installed with `forge install`: the upstream repository is large, and the
published `@chainlink/contracts` package as a whole is marked BUSL-1.1.

`forge fmt` skips this folder (`[fmt] ignore` in `foundry.toml`) so the files
stay identical to upstream. To check them, run from `contracts/`:

```sh
shasum -a 256 src/vendor/chainlink/libraries/*.sol src/vendor/chainlink/interfaces/*.sol src/vendor/chainlink/LICENSE
```
