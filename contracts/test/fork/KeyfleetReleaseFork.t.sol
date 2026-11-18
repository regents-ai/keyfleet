// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {RecordKeyfleets} from "../../script/RecordKeyfleets.s.sol";
import {LiveSubscriptionFork} from "./KeyfleetTradingFork.t.sol";

/// @dev Base's first release as pinned in `KeyfleetManifest`, its deployment block included, proved
/// against Base itself, and the record's and the Safe steps' whole run on a fork of Base at its
/// latest block, exactly as it stands: both take that release from the pins, whatever broadcast
/// log the repository holds. Each run writes through `runInto`, the function the real `run` calls
/// with its own folder, into a folder of this test's own under `rehearsal/`, which git ignores, and
/// the test removes that folder; no test opens the published record, a Safe batch or a broadcast
/// log, so each passes whether those are there or not. Nothing is signed or sent to Base. It runs
/// only when `BASE_RPC_URL` is set and skips itself otherwise.
contract KeyfleetReleaseForkTest is LiveSubscriptionFork {
    /// @dev The account that sent Base's first release, and the nonce of its first transaction:
    /// read from Base, and checked below against the addresses those nonces create.
    address private constant RELEASE_SENDER = 0x9b2C414614aEE294202c1219520955EF3B596031;
    uint64 private constant RELEASE_FIRST_NONCE = 50;
    address private constant SOMEONE_ELSE = address(0x50B0);

    string private constant RECORD_FOLDER = "rehearsal/release-fork-record";
    string private constant SAFE_FOLDER = "rehearsal/release-fork-safe";

    string private rpc;

    function setUp() public {
        rpc = vm.envOr("BASE_RPC_URL", string(""));
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

    /// @dev The pinned deployment block, proved from Base's own state. The release is
    /// `DeployKeyfleets`' five creations in order, the four deployers the pinned factory names and
    /// then the factory, and they are the addresses one account's nonces 50 to 54 create. At the end
    /// of the block before the pin that account had sent none of them and the first, the manager
    /// deployer, had no code; at the end of the pinned block both had changed. The other four have
    /// later nonces, so they landed in that block or after it: the pin is the lowest block any of the
    /// five landed in, which is what the record calls the deployment block. The public endpoint
    /// refuses log searches, so this reads state at the two edges instead.
    function test_thePinnedDeploymentBlockIsWhereTheReleaseBegan() public {
        RecordKeyfleets recorder = new RecordKeyfleets();
        KeyfleetFactory factory = KeyfleetFactory(recorder.BASE_KEYFLEET_FACTORY());
        uint256 pin = recorder.BASE_DEPLOYMENT_BLOCK();
        address[5] memory release = [
            address(factory.MANAGER_DEPLOYER()),
            address(factory.VOTES_DEPLOYER()),
            address(factory.TREASURY_DEPLOYER()),
            address(factory.REWARDS_DEPLOYER()),
            address(factory)
        ];
        for (uint256 i = 0; i < release.length; ++i) {
            assertEq(vm.computeCreateAddress(RELEASE_SENDER, RELEASE_FIRST_NONCE + i), release[i], "nonce by nonce");
        }

        vm.createSelectFork(rpc, pin - 1);
        assertEq(vm.getNonce(RELEASE_SENDER), RELEASE_FIRST_NONCE, "none of the five sent before the pin");
        assertEq(release[0].code.length, 0, "no manager deployer before the pin");
        vm.createSelectFork(rpc, pin);
        assertGt(vm.getNonce(RELEASE_SENDER), RELEASE_FIRST_NONCE, "the first of the five sent in the pinned block");
        assertGt(release[0].code.length, 0, "the manager deployer created in it");
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

    /// @dev The release's steps on the fork, from the Safe's address, up to phase 2 and every
    /// founding fleet created, whoever owns the randomness subscription. Then, for phase 3 and again
    /// for phase 4, with the subscription handed to another account, the step stops with that
    /// account's address; once the Regents Safe holds the subscription and lists the collection, the
    /// step's call opens the phase.
    function test_theDrawingPhaseStepsOnBaseWaitForTheSafesSubscription() public {
        KeyfleetSafeSteps steps = new KeyfleetSafeSteps();
        KeyfleetManifest.Manifest memory manifest = steps.readManifest("base");
        KeyfleetFactory factory = KeyfleetFactory(steps.BASE_KEYFLEET_FACTORY());
        KeyfleetKeys collection = factory.KEYS();
        _handSubscriptionTo(SOMEONE_ELSE);
        while (collection.phase() + 1 < steps.FIRST_DRAWING_PHASE()) {
            _asSafe(steps.foundingFleetCalls(manifest, factory));
            _asSafe(steps.advancePhaseCalls(manifest, factory, uint64(block.timestamp + 1)));
            vm.warp(block.timestamp + 1);
        }
        _asSafe(steps.foundingFleetCalls(manifest, factory));

        while (collection.phase() < collection.FINAL_PHASE()) {
            uint256 next = collection.phase() + 1;
            _handSubscriptionTo(SOMEONE_ELSE);
            vm.expectRevert(
                abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedByRegentsSafe.selector, SOMEONE_ELSE)
            );
            steps.advancePhaseCalls(manifest, factory, uint64(block.timestamp + 1));

            _subscriptionToTheSafe();
            KeyfleetSafeSteps.SafeCall[] memory calls =
                steps.advancePhaseCalls(manifest, factory, uint64(block.timestamp + 1));
            assertEq(calls[0].name, string.concat("phase-", vm.toString(next)));
            _asSafe(calls);
            assertEq(collection.phase(), next, "opened once the Safe holds it");
            vm.warp(block.timestamp + 1);
        }
    }

    function _asSafe(KeyfleetSafeSteps.SafeCall[] memory calls) private {
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(REGENTS_SAFE);
            Address.functionCall(calls[i].to, calls[i].data);
        }
    }
}
