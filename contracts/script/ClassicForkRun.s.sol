// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetManifest} from "./KeyfleetManifest.sol";
import {RecordKeyfleets} from "./RecordKeyfleets.s.sol";

/// @notice The Classic #1 fork run's deployed record: the live Base system as a local fork of Base
/// holds it, read back through `RecordKeyfleets`, the release's own record step, and written to
/// `RECORD_FILE` instead of the release's `deployments/base.deployed.json`, so a fork's state never
/// stands in for what is on Base. No part of a release.
/// @dev The fork keeps Base's chain id, 8453, so the record step checks the live system against
/// the Base manifest exactly as it would on Base. The factory is the one the Base deployment's
/// broadcast created (`broadcast/DeployKeyfleets.s.sol/8453/run-latest.json`). It sends nothing and
/// needs no signer. `platform/test/keyfleet/classic_fork_run_test.exs` runs it twice: before the
/// Safe creates Classic #1, and once Classic #1's sales are open, to seed the site before Keys 1
/// and 2 are bought.
contract ClassicForkRun is KeyfleetManifest {
    /// @notice The fork run's deployed record, in the shape of `deployments/base.deployed.json`.
    string public constant RECORD_FILE = "deployments/base-fork-run.json";

    /// @notice Reads the Base system and every fleet back from the chain and writes `RECORD_FILE`.
    function record() external {
        vm.writeJson(new RecordKeyfleets().record(readManifest("base"), readBroadcast()), RECORD_FILE);
    }
}
