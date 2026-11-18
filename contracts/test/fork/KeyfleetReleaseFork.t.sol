// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {RecordKeyfleets} from "../../script/RecordKeyfleets.s.sol";

/// @dev The record's and the Safe steps' whole `run` on a fork of Base at its latest block, exactly
/// as it stands, with no broadcast record of the release: both take Base's first release from
/// `KeyfleetManifest`. Each run writes its files under `deployments/` as a real run does, so each
/// test first requires that none of them is there, never overwriting a real record or batch, and
/// removes what the run wrote. Nothing is signed or sent to Base. It runs only when `BASE_RPC_URL`
/// is set and skips itself otherwise.
contract KeyfleetReleaseForkTest is Test {
    string private constant RELEASE_BROADCAST = "broadcast/DeployKeyfleets.s.sol/8453/run-latest.json";
    string private constant RECORD_FILE = "deployments/base.deployed.json";
    string private constant SAFE_FOLDER = "deployments/safe";

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    /// @dev The pinned factory is the live one: it names the pinned collection, which is its first
    /// creation and lists it as a factory. Base's own run gives exactly the pins.
    function test_thePinnedReleaseIsTheLiveSystem() public {
        RecordKeyfleets recorder = new RecordKeyfleets();
        KeyfleetFactory factory = KeyfleetFactory(recorder.BASE_KEYFLEET_FACTORY());
        KeyfleetKeys collection = KeyfleetKeys(recorder.BASE_KEYFLEET_COLLECTION());

        assertEq(address(factory.KEYS()), address(collection), "the factory names the collection");
        assertEq(vm.computeCreateAddress(address(factory), 1), address(collection), "which it created first");
        assertTrue(collection.isFactory(address(factory)), "and which lists it");
        assertFalse(vm.exists(RELEASE_BROADCAST), "no release broadcast");

        KeyfleetManifest.BroadcastSummary memory deployment = recorder.readDeployment();
        assertEq(address(deployment.factory), address(factory), "Base's factory");
        assertEq(deployment.deploymentBlock, 52_396_666, "Base's first block");
    }

    /// @dev The record's run writes Base's record with the pinned factory and first block, the
    /// same record `record` gives for them.
    function test_theRecordRunsOnBaseFromThePinnedRelease() public {
        RecordKeyfleets recorder = new RecordKeyfleets();
        assertFalse(vm.exists(RELEASE_BROADCAST), "no release broadcast");
        assertFalse(vm.exists(RECORD_FILE), "no record to overwrite");
        vm.setEnv("KEYFLEET_MANIFEST", "base");

        recorder.run();
        string memory written = vm.readFile(RECORD_FILE);
        vm.removeFile(RECORD_FILE);

        assertEq(vm.parseJsonUint(written, ".chainId"), 8453);
        assertEq(vm.parseJsonUint(written, ".deploymentBlock"), recorder.BASE_DEPLOYMENT_BLOCK(), "first block");
        assertEq(vm.parseJsonAddress(written, ".factory.address"), recorder.BASE_KEYFLEET_FACTORY(), "factory");
        assertEq(vm.parseJsonAddress(written, ".collection.address"), recorder.BASE_KEYFLEET_COLLECTION());
        KeyfleetManifest.BroadcastSummary memory pinned = KeyfleetManifest.BroadcastSummary({
            factory: KeyfleetFactory(recorder.BASE_KEYFLEET_FACTORY()),
            deploymentBlock: recorder.BASE_DEPLOYMENT_BLOCK()
        });
        string memory expected = recorder.record(recorder.readManifest("base"), pinned);
        assertEq(vm.parseJson(written), vm.parseJson(expected), "the whole record");
    }

    /// @dev The Safe steps' run writes one batch per founding fleet still missing (fleets 2 to 4
    /// while the collection is in phase 2), each the Safe's call to the pinned factory, after
    /// running it from the Safe's address on the fork.
    function test_theSafeStepsRunOnBaseFromThePinnedRelease() public {
        KeyfleetSafeSteps steps = new KeyfleetSafeSteps();
        assertFalse(vm.exists(RELEASE_BROADCAST), "no release broadcast");
        KeyfleetManifest.Manifest memory manifest = steps.readManifest("base");
        KeyfleetFactory factory = KeyfleetFactory(steps.BASE_KEYFLEET_FACTORY());
        KeyfleetSafeSteps.SafeCall[] memory calls = steps.foundingFleetCalls(manifest, factory);
        string[] memory files = new string[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            files[i] = string.concat(SAFE_FOLDER, "/base.", calls[i].name, ".json");
            assertFalse(vm.exists(files[i]), "no batch to overwrite");
        }
        bool hadFolder = vm.exists(SAFE_FOLDER);
        vm.setEnv("KEYFLEET_MANIFEST", "base");
        vm.setEnv("KEYFLEET_STEP", "founding-fleets");

        steps.run();
        string[] memory written = new string[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            written[i] = vm.readFile(files[i]);
            vm.removeFile(files[i]);
        }
        if (!hadFolder) vm.removeDir(SAFE_FOLDER, false);

        for (uint256 i = 0; i < calls.length; ++i) {
            assertEq(calls[i].to, address(factory), "a call to the pinned factory");
            assertEq(vm.parseJsonString(written[i], ".chainId"), "8453");
            assertEq(vm.parseJsonAddress(written[i], ".meta.createdFromSafeAddress"), manifest.bindings.safe);
            assertEq(vm.parseJsonAddress(written[i], ".transactions[0].to"), calls[i].to);
            assertEq(vm.parseJsonBytes(written[i], ".transactions[0].data"), calls[i].data);
        }
        assertEq(steps.foundingFleetCalls(manifest, factory).length, 0, "the run made every call on the fork");
    }
}
