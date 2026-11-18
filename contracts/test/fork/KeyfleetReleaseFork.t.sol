// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {RecordKeyfleets} from "../../script/RecordKeyfleets.s.sol";

/// @dev The record's and the Safe steps' whole run on a fork of Base at its latest block, exactly as
/// it stands: both take Base's first release from `KeyfleetManifest`, whatever broadcast log the
/// repository holds. Each run writes through `runInto`, the function the real `run` calls with its
/// own folder, into a folder of this test's own under `rehearsal/`, which git ignores, and the test
/// removes that folder; no test opens the published record, a Safe batch or a broadcast log, so
/// each passes whether those are there or not. Nothing is signed or sent to Base. It runs only when
/// `BASE_RPC_URL` is set and skips itself otherwise.
contract KeyfleetReleaseForkTest is Test {
    string private constant RECORD_FOLDER = "rehearsal/release-fork-record";
    string private constant SAFE_FOLDER = "rehearsal/release-fork-safe";

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    /// @dev The pinned factory is the live one: it names the pinned collection, which is its first
    /// creation and lists it as a factory. Base's own reader gives exactly the pins.
    function test_thePinnedReleaseIsTheLiveSystem() public {
        RecordKeyfleets recorder = new RecordKeyfleets();
        KeyfleetFactory factory = KeyfleetFactory(recorder.BASE_KEYFLEET_FACTORY());
        KeyfleetKeys collection = KeyfleetKeys(recorder.BASE_KEYFLEET_COLLECTION());

        assertEq(address(factory.KEYS()), address(collection), "the factory names the collection");
        assertEq(vm.computeCreateAddress(address(factory), 1), address(collection), "which it created first");
        assertTrue(collection.isFactory(address(factory)), "and which lists it");

        KeyfleetManifest.BroadcastSummary memory deployment = recorder.readDeployment();
        assertEq(address(deployment.factory), address(factory), "Base's factory");
        assertEq(deployment.deploymentBlock, recorder.BASE_DEPLOYMENT_BLOCK(), "Base's first block");
    }

    /// @dev The record's run writes Base's record with the pinned factory and first block, the
    /// same record `record` gives for them.
    function test_theRecordRunsOnBaseFromThePinnedRelease() public {
        RecordKeyfleets recorder = new RecordKeyfleets();
        vm.createDir(RECORD_FOLDER, true);
        vm.setEnv("KEYFLEET_MANIFEST", "base");

        recorder.runInto(RECORD_FOLDER);
        string memory written = vm.readFile(string.concat(RECORD_FOLDER, "/base.deployed.json"));
        vm.removeDir(RECORD_FOLDER, true);

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
        KeyfleetManifest.Manifest memory manifest = steps.readManifest("base");
        KeyfleetFactory factory = KeyfleetFactory(steps.BASE_KEYFLEET_FACTORY());
        KeyfleetSafeSteps.SafeCall[] memory calls = steps.foundingFleetCalls(manifest, factory);
        vm.setEnv("KEYFLEET_MANIFEST", "base");
        vm.setEnv("KEYFLEET_STEP", "founding-fleets");

        steps.runInto(SAFE_FOLDER);
        string[] memory written = new string[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            written[i] = vm.readFile(string.concat(SAFE_FOLDER, "/base.", calls[i].name, ".json"));
        }
        vm.removeDir(SAFE_FOLDER, true);

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
