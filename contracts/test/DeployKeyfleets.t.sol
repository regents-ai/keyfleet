// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeployKeyfleets} from "../script/DeployKeyfleets.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev The one thing the deployment asks of the Autolaunch factory: that it exists and publishes
/// the strategy the deployed manifest records. Nothing here is launched.
contract StrategyPublishingFactory {
    address public immutable strategy;

    constructor(address strategy_) {
        strategy = strategy_;
    }
}

contract DeployKeyfleetsTest is Test {
    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant Q = 10e18;
    uint64 private constant VOTING_WINDOW = 24 hours;
    address private constant SAFE = address(0x5AFE);
    address private constant TREASURY = address(0x7EA5);
    address private constant STAKING = address(0x57A1);
    address private constant STRATEGY = address(0x574A);
    address private constant BUYER = address(0xB0B);

    DeployKeyfleets private script;
    MockToken private regent;
    MockToken private usdc;
    StrategyPublishingFactory private factory;

    function setUp() public {
        script = new DeployKeyfleets();
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        factory = new StrategyPublishingFactory(STRATEGY);
    }

    function test_deployedFleetsCarryTheManifestAndTheDirectoryNamesThem() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        DeployKeyfleets.Deployment memory deployment = script.deploy(manifest);

        assertEq(deployment.registry.REGENT_SAFE(), SAFE, "Registry Safe");
        assertEq(deployment.registry.BASE_USDC(), address(usdc), "Registry USDC");

        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];
        for (uint256 slot = 0; slot < 4; ++slot) {
            Keyfleet fleet = deployment.fleets[slot];
            assertTrue(fleet.PRESET() == presets[slot], "Preset of slot");
            assertEq(fleet.Q(), manifest.fleets[slot].q, "Q");
            assertEq(fleet.name(), manifest.fleets[slot].name, "Name");
            assertEq(fleet.symbol(), manifest.fleets[slot].symbol, "Symbol");
            assertEq(address(fleet.REGENT()), address(regent), "REGENT");
            assertEq(address(fleet.USDC()), address(usdc), "USDC");
            assertEq(address(fleet.USDC()), deployment.registry.BASE_USDC(), "USDC is the registry's");
            assertEq(fleet.TREASURY(), TREASURY, "Treasury");
            assertEq(address(fleet.ASSET_REGISTRY()), address(deployment.registry), "Asset registry");
            assertEq(address(fleet.STAKING()), STAKING, "Staking");
            assertEq(address(fleet.FACTORY()), address(factory), "Autolaunch factory");
            assertEq(fleet.VOTES().VOTING_WINDOW(), VOTING_WINDOW, "Voting window");
            assertEq(fleet.REWARDS().FLEET(), address(fleet), "Reward ledger is the fleet's own");
            assertEq(address(fleet.VOTES().FLEET()), address(fleet), "Controller is the fleet's own");
            assertTrue(deployment.directory.isFleet(address(fleet)), "Directory names the fleet");

            uint256 price = fleet.nextPrice();
            regent.mint(BUYER, price);
            vm.startPrank(BUYER);
            regent.approve(address(fleet), price);
            fleet.purchase(BUYER, address(0), price, block.timestamp);
            vm.stopPrank();
            assertEq(
                fleet.tokenURI(1),
                string.concat(manifest.fleets[slot].baseTokenURI, "1"),
                "Metadata base is the fleet's own"
            );
        }

        assertEq(address(deployment.directory.SYNDICATE()), address(deployment.fleets[0]), "Slot 0");
        assertEq(address(deployment.directory.ACCELERANT()), address(deployment.fleets[3]), "Slot 3");
    }

    function test_deploySetsNoAllowlistFlag() public {
        DeployKeyfleets.Deployment memory deployment = script.deploy(_manifest());

        assertFalse(deployment.registry.factoryTokenAllowed(address(usdc)), "USDC is not admitted globally");
        assertFalse(
            deployment.registry.fleetTokenAllowed(address(deployment.fleets[0]), address(regent)),
            "REGENT is not admitted for a fleet"
        );
    }

    function test_manifestForAnotherChainIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, BASE_CHAIN_ID, ANVIL_CHAIN_ID));
        script.deploy(manifest);
    }

    function test_autolaunchFactoryWithoutCodeIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.autolaunchFactory = address(0xFAC7);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.AutolaunchFactoryMissing.selector, address(0xFAC7)));
        script.deploy(manifest);
    }

    function test_autolaunchFactoryWithoutCodeIsAcceptedOnlyWhenTheManifestAllowsIt() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.autolaunchFactory = address(0xFAC7);
        manifest.autolaunchFactoryMayBeEmpty = true;

        DeployKeyfleets.Deployment memory deployment = script.deploy(manifest);

        assertEq(address(deployment.fleets[0].FACTORY()), address(0xFAC7), "Factory recorded as given");
    }

    function test_baseIgnoresTheEmptyAutolaunchFactoryAllowance() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;
        manifest.autolaunchFactory = address(0xFAC7);
        manifest.autolaunchFactoryMayBeEmpty = true;
        vm.chainId(BASE_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.AutolaunchFactoryMissing.selector, address(0xFAC7)));
        script.deploy(manifest);
    }

    function test_suppliedRegistryIsReused() public {
        KeyfleetAssetRegistry existing = new KeyfleetAssetRegistry(SAFE, address(usdc));
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.assetRegistry = address(existing);

        DeployKeyfleets.Deployment memory deployment = script.deploy(manifest);

        assertEq(address(deployment.registry), address(existing), "Registry reused");
        assertEq(address(deployment.fleets[2].ASSET_REGISTRY()), address(existing), "Fleets point at it");
    }

    function test_suppliedRegistryUnderAnotherSafeIsRefused() public {
        KeyfleetAssetRegistry foreign = new KeyfleetAssetRegistry(address(0xBEEF), address(usdc));
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.assetRegistry = address(foreign);

        vm.expectRevert(abi.encodeWithSelector(DeployKeyfleets.RegistrySafeMismatch.selector, SAFE, address(0xBEEF)));
        script.deploy(manifest);
    }

    function test_manifestIsReadFieldByFieldWhateverItsKeyOrder() public view {
        string memory json = string.concat(
            '{"votingWindow": 7200, "assetRegistry": "0x00000000000000000000000000000000000000a7",',
            ' "autolaunchFactoryMayBeEmpty": true, "chainId": 31337,',
            ' "usdc": "0x00000000000000000000000000000000000000a2",',
            ' "regent": "0x00000000000000000000000000000000000000a1",',
            ' "staking": "0x00000000000000000000000000000000000000a4",',
            ' "treasury": "0x00000000000000000000000000000000000000a3",',
            ' "autolaunchFactory": "0x00000000000000000000000000000000000000a6",',
            ' "regentSafe": "0x00000000000000000000000000000000000000a5",',
            ' "fleets": {',
            '  "accelerant": {"symbol": "D", "q": "4000000000000000000000", "baseTokenURI": "u/d/", "name": "Fleet D"},',
            '  "syndicate": {"name": "Fleet A", "symbol": "A", "baseTokenURI": "u/a/", "q": "1000000000000000000000"},',
            '  "classic": {"q": "3000000000000000000000", "name": "Fleet C", "symbol": "C", "baseTokenURI": "u/c/"},',
            '  "cascade": {"baseTokenURI": "u/b/", "name": "Fleet B", "q": "2000000000000000000000", "symbol": "B"}',
            " }}"
        );

        KeyfleetManifest.Manifest memory manifest = script.parseManifest(json);

        assertEq(manifest.chainId, ANVIL_CHAIN_ID, "chainId");
        assertEq(manifest.regent, address(0xA1), "regent");
        assertEq(manifest.usdc, address(0xA2), "usdc");
        assertEq(manifest.treasury, address(0xA3), "treasury");
        assertEq(manifest.staking, address(0xA4), "staking");
        assertEq(manifest.regentSafe, address(0xA5), "regentSafe");
        assertEq(manifest.autolaunchFactory, address(0xA6), "autolaunchFactory");
        assertEq(manifest.assetRegistry, address(0xA7), "assetRegistry");
        assertTrue(manifest.autolaunchFactoryMayBeEmpty, "autolaunchFactoryMayBeEmpty");
        assertEq(manifest.votingWindow, 7200, "votingWindow");

        string[4] memory letters = ["A", "B", "C", "D"];
        string[4] memory lower = ["a", "b", "c", "d"];
        for (uint256 slot = 0; slot < 4; ++slot) {
            KeyfleetManifest.FleetSpec memory fleet = manifest.fleets[slot];
            assertEq(fleet.q, (slot + 1) * 1000e18, "q of the slot's own key");
            assertEq(fleet.name, string.concat("Fleet ", letters[slot]), "name of the slot's own key");
            assertEq(fleet.symbol, letters[slot], "symbol of the slot's own key");
            assertEq(fleet.baseTokenURI, string.concat("u/", lower[slot], "/"), "base of the slot's own key");
        }
    }

    function test_committedManifestsPassTheDeploymentRefusals() public {
        KeyfleetManifest.Manifest memory anvil = script.readManifest("anvil");
        DeployKeyfleets.Deployment memory lab = script.deploy(anvil);
        assertGt(address(lab.directory).code.length, 0, "The anvil manifest deploys on its chain");

        KeyfleetManifest.Manifest memory base = script.readManifest("base");
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(base.autolaunchFactory, address(factory).code);
        DeployKeyfleets.Deployment memory release = script.deploy(base);
        assertGt(address(release.directory).code.length, 0, "The Base manifest deploys once its factory exists");
    }

    function test_manifestVotingWindowWiderThanAFleetCanHoldIsRefused() public {
        string memory json = string.concat(
            '{"chainId": 31337,',
            ' "regent": "0x0000000000000000000000000000000000000001",',
            ' "usdc": "0x0000000000000000000000000000000000000002",',
            ' "treasury": "0x0000000000000000000000000000000000000003",',
            ' "staking": "0x0000000000000000000000000000000000000004",',
            ' "regentSafe": "0x0000000000000000000000000000000000000005",',
            ' "autolaunchFactory": "0x0000000000000000000000000000000000000006",',
            ' "assetRegistry": "0x0000000000000000000000000000000000000000",',
            ' "autolaunchFactoryMayBeEmpty": true,',
            ' "votingWindow": 18446744073709551616}'
        );

        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetManifest.VotingWindowTooLarge.selector, uint256(type(uint64).max) + 1)
        );
        script.parseManifest(json);
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
        manifest.fleets[0] = KeyfleetManifest.FleetSpec(Q, "Keyfleet Syndicate", "KEYFLEET", "https://k/syndicate/");
        manifest.fleets[1] = KeyfleetManifest.FleetSpec(Q, "Keyfleet Cascade", "KEYFLEET", "https://k/cascade/");
        manifest.fleets[2] = KeyfleetManifest.FleetSpec(Q, "Keyfleet Classic", "KEYFLEET", "https://k/classic/");
        manifest.fleets[3] = KeyfleetManifest.FleetSpec(Q, "Keyfleet Accelerant", "KEYFLEET", "https://k/accelerant/");
    }
}
