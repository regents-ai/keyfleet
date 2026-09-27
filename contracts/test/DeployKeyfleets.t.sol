// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeployKeyfleets} from "../script/DeployKeyfleets.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Reports six decimals, as Base USDC does, because a fleet refuses a USDC with any other.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

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
    uint64 private constant VOTING_WINDOW = 24 hours;
    address private constant SAFE = address(0x5AFE);
    address private constant STAKING = address(0x57A1);
    address private constant STRATEGY = address(0x574A);
    address private constant BUYER = address(0xB0B);
    bytes32 private constant KEY_HASH = keccak256("lab gas lane");
    bytes32 private constant TRAIT_TABLE = keccak256("trait table");

    event RevealRequestFailed(uint256 indexed tokenId);

    DeployKeyfleets private script;
    MockToken private regent;
    MockToken private usdc;
    StrategyPublishingFactory private factory;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private subscriptionId;

    function setUp() public {
        script = new DeployKeyfleets();
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        factory = new StrategyPublishingFactory(STRATEGY);
        vrf = new MockVRFCoordinatorV2Plus();
        vrf.addProvingKey(KEY_HASH, 30 gwei);
        subscriptionId = vrf.createSubscription();
    }

    /// @dev Each run puts one fleet on chain, and nothing else, so the four go on sale one at a time
    /// on shared wiring.
    function test_eachRunDeploysOneFleetCarryingTheManifest() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];
        string[4] memory keys = ["syndicate", "cascade", "classic", "accelerant"];
        KeyfleetManifest.Manifest memory manifest = _manifest();

        for (uint8 slot = 0; slot < 4; ++slot) {
            manifest.slot = slot;
            manifest.fleet = KeyfleetManifest.FleetSpec(
                string.concat("Fleet ", keys[slot]), "KEYFLEET", string.concat("https://k/", keys[slot], "/")
            );
            uint256 nonceBefore = vm.getNonce(address(script));

            Keyfleet fleet = script.deploy(manifest);

            assertEq(vm.getNonce(address(script)) - nonceBefore, 1, "One fleet and nothing else");
            assertTrue(fleet.PRESET() == presets[slot], "Preset of the slot");
            assertEq(fleet.name(), manifest.fleet.name, "Name");
            assertEq(fleet.symbol(), manifest.fleet.symbol, "Symbol");
            assertEq(address(fleet.USDC()), address(usdc), "USDC");
            assertEq(address(fleet.REGENT()), address(regent), "REGENT");
            assertEq(address(fleet.STAKING()), STAKING, "Staking");
            assertEq(address(fleet.FACTORY()), address(factory), "Autolaunch factory");
            assertEq(fleet.VOTES().VOTING_WINDOW(), VOTING_WINDOW, "Voting window");
            assertEq(fleet.REWARDS().FLEET(), address(fleet), "Reward ledger is the fleet's own");
            assertEq(address(fleet.VOTES().FLEET()), address(fleet), "Controller is the fleet's own");
            assertEq(address(fleet.VRF_COORDINATOR()), address(vrf), "VRF coordinator");
            assertEq(fleet.VRF_SUBSCRIPTION_ID(), subscriptionId, "VRF subscription");
            assertEq(fleet.VRF_KEY_HASH(), KEY_HASH, "VRF gas lane");
            assertEq(fleet.TRAIT_TABLE_HASH(), TRAIT_TABLE, "Trait table");

            // The Safe has not added the fleet to the subscription yet: the key sells all the same
            // and waits for a retry.
            uint256 price = fleet.nextPrice();
            assertEq(price, KeyfleetPresets.Q_USDC, "The first key costs 10 USDC");
            usdc.mint(BUYER, price);
            vm.startPrank(BUYER);
            usdc.approve(address(fleet), price);
            vm.expectEmit(true, false, false, false, address(fleet));
            emit RevealRequestFailed(1);
            fleet.purchase(BUYER, price, block.timestamp);
            vm.stopPrank();
            assertEq(
                fleet.tokenURI(1), string.concat(manifest.fleet.baseTokenURI, "1"), "Metadata base is the fleet's own"
            );
        }
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

        Keyfleet fleet = script.deploy(manifest);

        assertEq(address(fleet.FACTORY()), address(0xFAC7), "Factory recorded as given");
    }

    function test_baseIgnoresTheEmptyAutolaunchFactoryAllowance() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        manifest.autolaunchFactory = address(0xFAC7);
        manifest.autolaunchFactoryMayBeEmpty = true;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.AutolaunchFactoryMissing.selector, address(0xFAC7)));
        script.deploy(manifest);
    }

    /// @dev Invariant: on Base the only USDC a release can be paid in is Base USDC, whose six
    /// decimals every key price assumes; a look-alike never reaches a fleet.
    function test_baseManifestNamingAnyUsdcButBaseUsdcIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        manifest.usdc = address(usdc);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.UsdcNotBaseUsdc.selector, address(usdc)));
        script.deploy(manifest);
    }

    /// @dev Invariant: on Base the REGENT the Safe is told to admit is Base REGENT.
    function test_baseManifestNamingAnyRegentButBaseRegentIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        manifest.regent = address(regent);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.RegentNotBaseRegent.selector, address(regent)));
        script.deploy(manifest);
    }

    /// @dev Invariant: on every chain the manifest's REGENT holds code, the zero address included.
    function test_regentWithoutCodeIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.regent = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.RegentMissing.selector, address(0xBEEF)));
        script.deploy(manifest);

        manifest.regent = address(0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.RegentMissing.selector, address(0)));
        script.deploy(manifest);
    }

    /// @dev Invariant: on Base the only randomness a release can use is Chainlink's own Base
    /// coordinator on its 2 gwei gas lane.
    function test_baseManifestNamingAnyVrfCoordinatorOrGasLaneButBaseIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        manifest.vrf.coordinator = IVRFCoordinatorV2Plus(address(vrf));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfCoordinatorNotBase.selector, address(vrf)));
        script.deploy(manifest);

        manifest = _baseManifest();
        manifest.vrf.keyHash = KEY_HASH;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfKeyHashNotBase.selector, KEY_HASH));
        script.deploy(manifest);
    }

    function test_vrfCoordinatorWithoutCodeIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.vrf.coordinator = IVRFCoordinatorV2Plus(address(0xC0DE));

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfCoordinatorMissing.selector, address(0xC0DE)));
        script.deploy(manifest);
    }

    function test_vrfGasLaneTheCoordinatorDoesNotKnowIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.vrf.keyHash = keccak256("no such lane");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfKeyHashUnknown.selector, keccak256("no such lane")));
        script.deploy(manifest);
    }

    function test_vrfSubscriptionTheCoordinatorDoesNotKnowIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.vrf.subscriptionId = 0;

        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        script.deploy(manifest);
    }

    function test_manifestWithoutATraitTableIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.traitTableHash = bytes32(0);

        vm.expectRevert(Keyfleet.TraitTableHashZero.selector);
        script.deploy(manifest);
    }

    function test_manifestVotingWindowWiderThanAFleetCanHoldIsRefused() public {
        string memory json = string.concat(
            '{"chainId": 31337,',
            ' "regent": "0x0000000000000000000000000000000000000001",',
            ' "usdc": "0x0000000000000000000000000000000000000002",',
            ' "staking": "0x0000000000000000000000000000000000000004",',
            ' "regentSafe": "0x0000000000000000000000000000000000000005",',
            ' "autolaunchFactory": "0x0000000000000000000000000000000000000006",',
            ' "autolaunchFactoryMayBeEmpty": true,',
            ' "votingWindow": 18446744073709551616}'
        );

        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetManifest.VotingWindowTooLarge.selector, uint256(type(uint64).max) + 1)
        );
        script.parseManifest(json, "classic");
    }

    function test_manifestIsReadFieldByFieldForTheNamedFleetWhateverItsKeyOrder() public {
        string memory json = string.concat(
            '{"votingWindow": 7200, "autolaunchFactoryMayBeEmpty": true, "chainId": 31337,',
            ' "usdc": "0x00000000000000000000000000000000000000a2",',
            ' "regent": "0x00000000000000000000000000000000000000a1",',
            ' "staking": "0x00000000000000000000000000000000000000a4",',
            ' "autolaunchFactory": "0x00000000000000000000000000000000000000a6",',
            ' "regentSafe": "0x00000000000000000000000000000000000000a5",',
            ' "traitTableHash": "0x00000000000000000000000000000000000000000000000000000000000000c4",',
            ' "vrf": {"keyHash": "0x00000000000000000000000000000000000000000000000000000000000000c3",',
            '  "subscriptionId": "115792089237316195423570985008687907853269984665640564039457584007913129639935",',
            '  "coordinator": "0x00000000000000000000000000000000000000c1"},',
            ' "fleets": {',
            '  "accelerant": {"symbol": "D", "baseTokenURI": "u/d/", "name": "Fleet D"},',
            '  "syndicate": {"name": "Fleet A", "symbol": "A", "baseTokenURI": "u/a/"},',
            '  "classic": {"name": "Fleet C", "symbol": "C", "baseTokenURI": "u/c/"},',
            '  "cascade": {"baseTokenURI": "u/b/", "name": "Fleet B", "symbol": "B"}',
            " }}"
        );

        KeyfleetManifest.Manifest memory manifest = script.parseManifest(json, "classic");

        assertEq(manifest.chainId, ANVIL_CHAIN_ID, "chainId");
        assertEq(manifest.regent, address(0xA1), "regent");
        assertEq(manifest.usdc, address(0xA2), "usdc");
        assertEq(manifest.staking, address(0xA4), "staking");
        assertEq(manifest.regentSafe, address(0xA5), "regentSafe");
        assertEq(manifest.autolaunchFactory, address(0xA6), "autolaunchFactory");
        assertTrue(manifest.autolaunchFactoryMayBeEmpty, "autolaunchFactoryMayBeEmpty");
        assertEq(manifest.votingWindow, 7200, "votingWindow");
        assertEq(address(manifest.vrf.coordinator), address(0xC1), "vrf.coordinator");
        assertEq(manifest.vrf.subscriptionId, type(uint256).max, "vrf.subscriptionId, all 78 digits");
        assertEq(manifest.vrf.keyHash, bytes32(uint256(0xC3)), "vrf.keyHash");
        assertEq(manifest.traitTableHash, bytes32(uint256(0xC4)), "traitTableHash");

        string[4] memory keys = ["syndicate", "cascade", "classic", "accelerant"];
        string[4] memory letters = ["A", "B", "C", "D"];
        string[4] memory lower = ["a", "b", "c", "d"];
        for (uint256 slot = 0; slot < 4; ++slot) {
            manifest = script.parseManifest(json, keys[slot]);
            assertEq(manifest.slot, slot, "slot of the key");
            assertEq(manifest.fleet.name, string.concat("Fleet ", letters[slot]), "name of the key's own fleet");
            assertEq(manifest.fleet.symbol, letters[slot], "symbol of the key's own fleet");
            assertEq(manifest.fleet.baseTokenURI, string.concat("u/", lower[slot], "/"), "base of the key's own fleet");
        }

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.UnknownFleet.selector, "Classic"));
        script.parseManifest(json, "Classic");
    }

    /// @dev The committed manifests name Base's coordinator and 2 gwei gas lane, and carry a zero
    /// subscription and a zero trait table until the operator writes in the subscription the Safe
    /// owns and the final trait table's hash. Until then no fleet can be deployed; with both written
    /// in, every other refusal passes for Classic, the fleet that opens first.
    function test_committedManifestsPassTheDeploymentRefusalsOnceSubscriptionAndTraitTableAreWrittenIn() public {
        KeyfleetManifest.Manifest memory anvil = script.readManifest("anvil", "classic");
        vm.etch(anvil.usdc, address(usdc).code);
        vm.etch(anvil.regent, address(regent).code);
        uint256 labSubscription = _standInForBaseCoordinator();
        assertEq(address(anvil.vrf.coordinator), script.BASE_VRF_COORDINATOR(), "The lab forks Base's coordinator");
        assertEq(anvil.vrf.keyHash, script.BASE_VRF_KEY_HASH(), "The lab uses Base's gas lane");

        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        script.deploy(anvil);
        anvil.vrf.subscriptionId = labSubscription;
        vm.expectRevert(Keyfleet.TraitTableHashZero.selector);
        script.deploy(anvil);
        anvil.traitTableHash = TRAIT_TABLE;
        Keyfleet lab = script.deploy(anvil);
        assertGt(address(lab).code.length, 0, "The anvil manifest deploys on its chain");

        KeyfleetManifest.Manifest memory base = script.readManifest("base", "classic");
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(base.autolaunchFactory, address(factory).code);
        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        script.deploy(base);
        base.vrf.subscriptionId = labSubscription;
        base.traitTableHash = TRAIT_TABLE;
        Keyfleet release = script.deploy(base);
        assertGt(address(release).code.length, 0, "The Base manifest deploys once its factory exists");
    }

    /// @dev Puts the mock coordinator's code at Base's coordinator address, registers Base's gas
    /// lane there and opens a subscription on it, as the operator does on a fork.
    function _standInForBaseCoordinator() private returns (uint256 baseSubscription) {
        MockVRFCoordinatorV2Plus base = MockVRFCoordinatorV2Plus(script.BASE_VRF_COORDINATOR());
        vm.etch(address(base), address(vrf).code);
        base.addProvingKey(script.BASE_VRF_KEY_HASH(), 2 gwei);
        baseSubscription = base.createSubscription();
    }

    /// @dev A Base manifest on Base, paid in Base USDC, naming Base REGENT and answered by Base's
    /// VRF coordinator on its 2 gwei lane, all stood in for by the local mocks' code.
    function _baseManifest() private returns (KeyfleetManifest.Manifest memory manifest) {
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(script.BASE_USDC(), address(usdc).code);
        vm.etch(script.BASE_REGENT(), address(regent).code);
        uint256 baseSubscription = _standInForBaseCoordinator();
        manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;
        manifest.usdc = script.BASE_USDC();
        manifest.regent = script.BASE_REGENT();
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(script.BASE_VRF_COORDINATOR()),
            subscriptionId: baseSubscription,
            keyHash: script.BASE_VRF_KEY_HASH()
        });
    }

    function _manifest() private view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.regent = address(regent);
        manifest.usdc = address(usdc);
        manifest.staking = STAKING;
        manifest.regentSafe = SAFE;
        manifest.autolaunchFactory = address(factory);
        manifest.autolaunchFactoryMayBeEmpty = false;
        manifest.votingWindow = VOTING_WINDOW;
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
        });
        manifest.traitTableHash = TRAIT_TABLE;
        manifest.slot = 2;
        manifest.fleet = KeyfleetManifest.FleetSpec("Keyfleet Classic", "KEYFLEET", "https://k/classic/");
    }
}
