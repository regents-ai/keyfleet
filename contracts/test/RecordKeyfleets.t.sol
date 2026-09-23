// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployKeyfleets} from "../script/DeployKeyfleets.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {RecordKeyfleets} from "../script/RecordKeyfleets.s.sol";
import {KeyfleetDirectory} from "../src/KeyfleetDirectory.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {MockToken, StrategyPublishingFactory} from "./DeployKeyfleets.t.sol";

/// @dev Stands in for the Autolaunch strategy: the record step reads only its address and its code.
contract StandInStrategy {}

contract RecordKeyfleetsTest is Test {
    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint64 private constant VOTING_WINDOW = 24 hours;
    address private constant SAFE = address(0x5AFE);
    address private constant TREASURY = address(0x7EA5);
    address private constant STAKING = address(0x57A1);
    uint256 private constant DEPLOYMENT_BLOCK = 7;

    DeployKeyfleets private deployer;
    RecordKeyfleets private recorder;
    MockToken private regent;
    MockToken private usdc;
    StandInStrategy private strategy;
    StrategyPublishingFactory private factory;

    function setUp() public {
        deployer = new DeployKeyfleets();
        recorder = new RecordKeyfleets();
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        strategy = new StandInStrategy();
        factory = new StrategyPublishingFactory(address(strategy));
    }

    function test_recordPublishesTheReleaseAsTheChainReportsIt() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        DeployKeyfleets.Deployment memory deployment = deployer.deploy(manifest);

        string memory json = recorder.record(manifest, _summary(deployment.directory));

        assertEq(vm.parseJsonUint(json, ".chainId"), ANVIL_CHAIN_ID, "Chain");
        assertEq(vm.parseJsonUint(json, ".deploymentBlock"), DEPLOYMENT_BLOCK, "Deployment block");
        assertEq(vm.parseJsonAddress(json, ".directory"), address(deployment.directory), "Directory");
        assertEq(
            vm.parseJsonBytes32(json, ".directoryCodeHash"), address(deployment.directory).codehash, "Directory code"
        );
        assertEq(vm.parseJsonAddress(json, ".assetRegistry"), address(deployment.registry), "Registry");
        assertEq(vm.parseJsonAddress(json, ".regent"), manifest.regent, "REGENT as the manifest names it");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "USDC");
        assertEq(vm.parseJsonUint(json, ".qUsdc"), KeyfleetPresets.Q_USDC, "Every first key costs 10 USDC");
        assertEq(vm.parseJsonAddress(json, ".treasury"), TREASURY, "Treasury");
        assertEq(vm.parseJsonAddress(json, ".staking"), STAKING, "Staking");
        assertEq(vm.parseJsonAddress(json, ".regentSafe"), SAFE, "Regents Safe");
        assertEq(vm.parseJsonUint(json, ".votingWindow"), VOTING_WINDOW, "Voting window");

        string[4] memory keys = ["syndicate", "cascade", "classic", "accelerant"];
        uint256[4] memory supplies = [uint256(46_365), 46_365, 144, 2000];
        for (uint256 slot = 0; slot < 4; ++slot) {
            string memory key = string.concat(".fleets.", keys[slot]);
            assertEq(
                vm.parseJsonBytes32(json, string.concat(key, ".codeHash")),
                address(deployment.fleets[slot]).codehash,
                "Fleet code"
            );
            assertEq(
                vm.parseJsonAddress(json, string.concat(key, ".address")), address(deployment.fleets[slot]), "Fleet"
            );
            assertEq(
                vm.parseJsonAddress(json, string.concat(key, ".rewards")),
                address(deployment.fleets[slot].REWARDS()),
                "Ledger"
            );
            assertEq(
                vm.parseJsonAddress(json, string.concat(key, ".votes")),
                address(deployment.fleets[slot].VOTES()),
                "Controller"
            );
            assertEq(vm.parseJsonString(json, string.concat(key, ".name")), manifest.fleets[slot].name, "Name");
            assertEq(vm.parseJsonString(json, string.concat(key, ".symbol")), manifest.fleets[slot].symbol, "Symbol");
            assertEq(
                vm.parseJsonString(json, string.concat(key, ".baseTokenURI")),
                manifest.fleets[slot].baseTokenURI,
                "Metadata base read from the fleet"
            );
            assertEq(vm.parseJsonUint(json, string.concat(key, ".maxSupply")), supplies[slot], "Supply");

            address[] memory perFleet =
                vm.parseJsonAddressArray(json, string.concat(".initialAssetFlags.fleets.", keys[slot]));
            assertEq(perFleet.length, 2, "Two flags per fleet");
            assertEq(perFleet[0], address(usdc), "USDC per fleet");
            assertEq(perFleet[1], address(regent), "REGENT per fleet");
        }

        assertEq(vm.parseJsonUint(json, ".bounds.fibonacciLevels"), 20, "Levels");
        assertEq(vm.parseJsonUint(json, ".bounds.fibonacciMaxTokenId"), 46_365, "Highest token id");
        assertEq(vm.parseJsonUint(json, ".bounds.classicSupply"), 144, "Classic seats");
        assertEq(vm.parseJsonUint(json, ".bounds.accelerantMaxKeys"), 2000, "Accelerant cap");
        assertEq(vm.parseJsonUint(json, ".bounds.fibonacciAutolaunchMinKeys"), 86, "Launch after level 7");
        assertEq(vm.parseJsonUint(json, ".bounds.fleetTechAutolaunchMinKeys"), 100, "Launch after 100 keys");
        assertEq(vm.parseJsonUint(json, ".bounds.maxRewardAssets"), 8, "Reward-asset bound");
        assertEq(vm.parseJsonUint(json, ".bounds.maxCohorts"), 32, "Cohort bound");

        assertEq(vm.parseJsonUint(json, ".fees.protocolBps"), 500, "Protocol bps");
        assertEq(vm.parseJsonUint(json, ".fees.referralBps"), 1000, "Referral bps");
        assertEq(vm.parseJsonUint(json, ".fees.accelerantCapitalBps"), 1000, "Accelerant capital bps");
        assertEq(vm.parseJsonUint(json, ".fees.depositFeeBps"), 200, "Deposit fee bps");
        assertEq(vm.parseJsonUint(json, ".fees.bpsDenominator"), 10_000, "Bps denominator");

        assertEq(vm.parseJsonString(json, ".autolaunch.abi"), "RegentsAutolaunchFactoryV1", "Factory ABI");
        assertEq(vm.parseJsonAddress(json, ".autolaunch.factory"), address(factory), "Autolaunch factory");
        assertEq(vm.parseJsonBytes32(json, ".autolaunch.factoryCodeHash"), address(factory).codehash, "Factory code");
        assertEq(vm.parseJsonAddress(json, ".autolaunch.strategy"), address(strategy), "Strategy read off the factory");
        assertEq(vm.parseJsonBytes32(json, ".autolaunch.strategyCodeHash"), address(strategy).codehash, "Strategy code");
        assertFalse(vm.parseJsonBool(json, ".autolaunch.factoryMayBeEmpty"), "No waiver in force");
        assertTrue(bytes(vm.parseJsonString(json, ".autolaunch.readiness")).length > 0, "Readiness");

        assertEq(vm.parseJsonString(json, ".initialAssetFlags.status"), "awaiting the Regents Safe", "Flag status");
        address[] memory global = vm.parseJsonAddressArray(json, ".initialAssetFlags.global");
        assertEq(global.length, 2, "Two global flags");
        assertEq(global[0], address(usdc), "USDC globally");
        assertEq(global[1], address(regent), "REGENT globally");

        assertEq(vm.parseJsonString(json, ".disclosures.chat"), "Rooms and messages are public to read.", "Chat");
        assertEq(
            vm.parseJsonString(json, ".disclosures.refunds"),
            "No refunds and no escrow. A recorded payment is not proof of delivery.",
            "Refunds"
        );
        assertEq(vm.parseJsonString(json, ".disclosures.serviceRewardEligibility"), "Keys only.", "Eligibility");
        assertTrue(bytes(vm.parseJsonString(json, ".disclosures.feeComposition")).length > 0, "Fee composition");
        assertTrue(bytes(vm.parseJsonString(json, ".disclosures.safeAuthority")).length > 0, "Safe authority");
    }

    function test_recordOfALabWithoutTheAutolaunchFactoryRecordsNoStrategy() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.autolaunchFactory = address(0xFAC7);
        manifest.autolaunchFactoryMayBeEmpty = true;
        DeployKeyfleets.Deployment memory deployment = deployer.deploy(manifest);

        string memory json = recorder.record(manifest, _summary(deployment.directory));

        assertEq(vm.parseJsonAddress(json, ".autolaunch.strategy"), address(0), "No strategy to read");
        assertEq(vm.parseJsonBytes32(json, ".autolaunch.factoryCodeHash"), bytes32(0), "No factory code");
        assertTrue(vm.parseJsonBool(json, ".autolaunch.factoryMayBeEmpty"), "The lab shape is recorded");
    }

    function test_recordRefusesEveryValueThatDiffersFromTheManifest() public {
        KeyfleetDirectory directory = deployer.deploy(_manifest()).directory;
        KeyfleetManifest.Manifest memory manifest;

        manifest = _manifest();
        manifest.assetRegistry = address(0xBEEF);
        _expectRecordRefused(manifest, directory, _released("assetRegistry"));

        manifest = _manifest();
        manifest.regentSafe = address(0xBEEF);
        _expectRecordRefused(manifest, directory, _released("regentSafe"));

        manifest = _manifest();
        manifest.usdc = address(0xBEEF);
        _expectRecordRefused(manifest, directory, _released("usdc"));

        manifest = _manifest();
        manifest.treasury = address(0xBEEF);
        _expectRecordRefused(manifest, directory, _released("treasury"));

        manifest = _manifest();
        manifest.staking = address(0xBEEF);
        _expectRecordRefused(manifest, directory, _released("staking"));

        manifest = _manifest();
        manifest.autolaunchFactory = address(regent);
        _expectRecordRefused(manifest, directory, _released("autolaunchFactory"));

        manifest = _manifest();
        manifest.votingWindow = 2 hours;
        _expectRecordRefused(manifest, directory, _released("votingWindow"));

        manifest = _manifest();
        manifest.fleets[1].name = "Another name";
        _expectRecordRefused(manifest, directory, _fleet(1, "name"));

        manifest = _manifest();
        manifest.fleets[2].symbol = "OTHER";
        _expectRecordRefused(manifest, directory, _fleet(2, "symbol"));

        manifest = _manifest();
        manifest.fleets[3].baseTokenURI = "https://k/other/";
        _expectRecordRefused(manifest, directory, _fleet(3, "baseTokenURI"));
    }

    function test_recordRefusesAManifestForAnotherChain() public {
        KeyfleetDirectory directory = deployer.deploy(_manifest()).directory;
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;

        _expectRecordRefused(
            manifest,
            directory,
            abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, BASE_CHAIN_ID, ANVIL_CHAIN_ID)
        );
    }

    function test_emptyFactoryWaiverIsNeverRecordedOnBase() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        manifest.autolaunchFactoryMayBeEmpty = true;
        KeyfleetDirectory directory = deployer.deploy(manifest).directory;

        string memory json = recorder.record(manifest, _summary(directory));

        assertFalse(vm.parseJsonBool(json, ".autolaunch.factoryMayBeEmpty"), "Base ignores the waiver");
    }

    /// @dev Invariant: a Base record never publishes a USDC or a REGENT other than Base's own, even
    /// for a release that was deployed correctly.
    function test_recordOnBaseRefusesAnyUsdcOrRegentButBase() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        KeyfleetDirectory directory = deployer.deploy(manifest).directory;

        manifest.usdc = address(usdc);
        _expectRecordRefused(
            manifest, directory, abi.encodeWithSelector(KeyfleetManifest.UsdcNotBaseUsdc.selector, address(usdc))
        );

        manifest = _baseManifest();
        manifest.regent = address(regent);
        _expectRecordRefused(
            manifest, directory, abi.encodeWithSelector(KeyfleetManifest.RegentNotBaseRegent.selector, address(regent))
        );
    }

    /// @dev Invariant: the REGENT the record step tells the Safe to admit always holds code, so a
    /// zero or mistyped address is never published into `regent` or `initialAssetFlags`.
    function test_recordRefusesARegentWithoutCode() public {
        KeyfleetDirectory directory = deployer.deploy(_manifest()).directory;
        KeyfleetManifest.Manifest memory manifest = _manifest();

        manifest.regent = address(0xBEEF);
        _expectRecordRefused(
            manifest, directory, abi.encodeWithSelector(KeyfleetManifest.RegentMissing.selector, address(0xBEEF))
        );

        manifest.regent = address(0);
        _expectRecordRefused(
            manifest, directory, abi.encodeWithSelector(KeyfleetManifest.RegentMissing.selector, address(0))
        );
    }

    function test_recordRefusesADirectoryWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.DirectoryMissing.selector, address(0xD1)));
        recorder.record(_manifest(), _summary(KeyfleetDirectory(address(0xD1))));
    }

    function test_broadcastNamesItsDirectoryAndItsEarliestBlock() public view {
        RecordKeyfleets.BroadcastSummary memory summary = recorder.parseBroadcast(
            _broadcast(
                string.concat(
                    '{"status": "0x1", "blockNumber": "0x10"}, {"status": "0x1", "blockNumber": "0xf"},',
                    ' {"status": "0x1", "blockNumber": "0x11"}'
                )
            )
        );

        assertEq(address(summary.directory), address(0xD1), "Directory from its creation");
        assertEq(summary.deploymentBlock, 15, "Lowest receipt block, neither the first nor the last");
    }

    function test_broadcastWithAFailedReceiptIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.BroadcastReceiptFailed.selector, 1));
        recorder.parseBroadcast(
            _broadcast(
                string.concat(
                    '{"status": "0x1", "blockNumber": "0xf"}, {"status": "0x0", "blockNumber": "0xf"},',
                    ' {"status": "0x1", "blockNumber": "0xf"}'
                )
            )
        );
    }

    function test_broadcastWithATransactionAwaitingItsReceiptIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.BroadcastIncomplete.selector, 3, 2));
        recorder.parseBroadcast(
            _broadcast('{"status": "0x1", "blockNumber": "0xf"}, {"status": "0x1", "blockNumber": "0xf"}')
        );
    }

    function test_broadcastWithoutADirectoryIsRefused() public {
        string memory json = string.concat(
            '{"transactions": [',
            '{"contractName": "KeyfleetAssetRegistry", "contractAddress": "0x00000000000000000000000000000000000000a1"}',
            '], "receipts": [{"status": "0x1", "blockNumber": "0xf"}]}'
        );

        vm.expectRevert(RecordKeyfleets.DirectoryNotInBroadcast.selector);
        recorder.parseBroadcast(json);
    }

    /// @dev A broadcast of a registry, a fleet and a directory, in the shape Forge writes, with the
    /// given receipts.
    function _broadcast(string memory receipts) private pure returns (string memory) {
        return string.concat(
            '{"transactions": [',
            '{"contractName": "KeyfleetAssetRegistry", "contractAddress": "0x00000000000000000000000000000000000000a1"},',
            '{"contractName": "Keyfleet", "contractAddress": "0x00000000000000000000000000000000000000f1"},',
            '{"contractName": "KeyfleetDirectory", "contractAddress": "0x00000000000000000000000000000000000000d1"}',
            '], "receipts": [',
            receipts,
            "]}"
        );
    }

    function _expectRecordRefused(
        KeyfleetManifest.Manifest memory manifest,
        KeyfleetDirectory directory,
        bytes memory expected
    ) private {
        vm.expectRevert(expected);
        recorder.record(manifest, _summary(directory));
    }

    function _released(string memory field) private pure returns (bytes memory) {
        return abi.encodeWithSelector(RecordKeyfleets.RecordedMismatch.selector, field);
    }

    function _fleet(uint8 slot, string memory field) private pure returns (bytes memory) {
        return abi.encodeWithSelector(RecordKeyfleets.RecordedFleetMismatch.selector, slot, field);
    }

    function _summary(KeyfleetDirectory directory) private pure returns (RecordKeyfleets.BroadcastSummary memory) {
        return RecordKeyfleets.BroadcastSummary({directory: directory, deploymentBlock: DEPLOYMENT_BLOCK});
    }

    /// @dev A Base manifest on Base, paid in Base USDC and naming Base REGENT, both stood in for by
    /// the local mocks' code.
    function _baseManifest() private returns (KeyfleetManifest.Manifest memory manifest) {
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(deployer.BASE_USDC(), address(usdc).code);
        vm.etch(deployer.BASE_REGENT(), address(regent).code);
        manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;
        manifest.usdc = deployer.BASE_USDC();
        manifest.regent = deployer.BASE_REGENT();
    }

    function _manifest() private view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.regent = address(regent);
        manifest.usdc = address(usdc);
        manifest.treasury = TREASURY;
        manifest.staking = STAKING;
        manifest.regentSafe = SAFE;
        manifest.autolaunchFactory = address(factory);
        manifest.assetRegistry = address(0);
        manifest.autolaunchFactoryMayBeEmpty = false;
        manifest.votingWindow = VOTING_WINDOW;
        manifest.fleets[0] = KeyfleetManifest.FleetSpec("Keyfleet Syndicate", "KEYFLEET", "https://k/syndicate/");
        manifest.fleets[1] = KeyfleetManifest.FleetSpec("Keyfleet Cascade", "KEYFLEET", "https://k/cascade/");
        manifest.fleets[2] = KeyfleetManifest.FleetSpec("Keyfleet Classic", "KEYFLEET", "https://k/classic/");
        manifest.fleets[3] = KeyfleetManifest.FleetSpec("Keyfleet Accelerant", "KEYFLEET", "https://k/accelerant/");
    }
}
