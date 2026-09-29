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

/// @dev Reports six decimals, as Ethereum USDC does, because a fleet refuses a USDC with any other.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployKeyfleetsTest is Test {
    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    uint256 private constant ETHEREUM_CHAIN_ID = 1;
    address private constant SAFE = address(0x5AFE);
    address private constant REGENTS_SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address private constant BUYER = address(0xB0B);
    bytes32 private constant KEY_HASH = keccak256("lab gas lane");
    bytes32 private constant TRAIT_TABLE = keccak256("trait table");

    event RevealRequestFailed(uint256 indexed tokenId);

    DeployKeyfleets private script;
    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private subscriptionId;

    function setUp() public {
        script = new DeployKeyfleets();
        usdc = new MockToken("USD Coin", "USDC");
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
            assertEq(fleet.PROTOCOL_TREASURY(), SAFE, "Protocol treasury");
            assertEq(fleet.REWARDS().FLEET(), address(fleet), "Reward ledger is the fleet's own");
            assertEq(address(fleet.VOTES().FLEET()), address(fleet), "Controller is the fleet's own");
            assertEq(address(fleet.SHARDS().FLEET()), address(fleet), "Shard record is the fleet's own");
            assertEq(address(fleet.VRF_COORDINATOR()), address(vrf), "VRF coordinator");
            assertEq(fleet.VRF_SUBSCRIPTION_ID(), subscriptionId, "VRF subscription");
            assertEq(fleet.VRF_KEY_HASH(), KEY_HASH, "VRF gas lane");
            assertEq(fleet.TRAIT_TABLE_HASH(), TRAIT_TABLE, "Trait table");

            // The Safe has not added the fleet to the subscription yet: the key sells all the same
            // and waits for a retry.
            uint256 price = fleet.nextPrice();
            uint256 firstPrice = presets[slot] == KeyfleetPresets.Preset.FleetTechClassic
                ? KeyfleetPresets.classicPrice(1)
                : KeyfleetPresets.Q_USDC;
            assertEq(price, firstPrice, "The first key costs 8 USDC on Classic and 10 USDC on the others");
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
            assertEq(fleet.protocolShareOwed(), price / 10, "A tenth of the sale is owed to the Safe");
        }
    }

    function test_manifestForAnotherChainIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = ETHEREUM_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, ETHEREUM_CHAIN_ID, ANVIL_CHAIN_ID));
        script.deploy(manifest);
    }

    /// @dev Invariant: every fleet names the Safe that receives its protocol share; a zero
    /// treasury never reaches a fleet.
    function test_manifestWithoutAProtocolTreasuryIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.protocolTreasury = address(0);

        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        script.deploy(manifest);
    }

    /// @dev Invariant: on Ethereum the only USDC a release can be paid in is Ethereum USDC, whose
    /// six decimals every key price assumes; a look-alike never reaches a fleet.
    function test_ethereumManifestNamingAnyUsdcButEthereumUsdcIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _ethereumManifest();
        manifest.usdc = address(usdc);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.UsdcNotEthereumUsdc.selector, address(usdc)));
        script.deploy(manifest);
    }

    /// @dev Invariant: on Ethereum the protocol share of every fleet goes to the Regents Safe and
    /// nowhere else.
    function test_ethereumManifestNamingAnyTreasuryButTheRegentsSafeIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _ethereumManifest();
        manifest.protocolTreasury = SAFE;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.ProtocolTreasuryNotRegentsSafe.selector, SAFE));
        script.deploy(manifest);
    }

    /// @dev Invariant: on Ethereum the only randomness a release can use is Chainlink's own
    /// Ethereum coordinator on its 200 gwei gas lane.
    function test_ethereumManifestNamingAnyVrfCoordinatorOrGasLaneButEthereumsIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _ethereumManifest();
        manifest.vrf.coordinator = IVRFCoordinatorV2Plus(address(vrf));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfCoordinatorNotEthereum.selector, address(vrf)));
        script.deploy(manifest);

        manifest = _ethereumManifest();
        manifest.vrf.keyHash = KEY_HASH;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfKeyHashNotEthereum.selector, KEY_HASH));
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

    function test_manifestIsReadFieldByFieldForTheNamedFleetWhateverItsKeyOrder() public {
        string memory json = string.concat(
            '{"chainId": 31337,',
            ' "usdc": "0x00000000000000000000000000000000000000a2",',
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
        assertEq(manifest.usdc, address(0xA2), "usdc");
        assertEq(manifest.protocolTreasury, address(0), "the treasury never comes from the file");
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

    /// @dev The committed manifests name Ethereum's coordinator and 200 gwei gas lane, and carry a
    /// zero subscription and a zero trait table until the operator writes in the subscription the
    /// Safe owns and the final trait table's hash. Until then no fleet can be deployed; with both
    /// written in, every other refusal passes for Classic, the fleet that opens first. Both take the
    /// protocol treasury from the environment, never from the file.
    function test_committedManifestsPassTheDeploymentRefusalsOnceSubscriptionAndTraitTableAreWrittenIn() public {
        vm.setEnv("KEYFLEET_PROTOCOL_TREASURY", vm.toString(SAFE));
        KeyfleetManifest.Manifest memory anvil = script.readManifest("anvil", "classic");
        assertEq(anvil.protocolTreasury, SAFE, "The treasury comes from the environment");
        vm.etch(anvil.usdc, address(usdc).code);
        uint256 labSubscription = _standInForEthereumCoordinator();
        assertEq(anvil.usdc, script.ETHEREUM_USDC(), "The lab forks Ethereum's USDC");
        assertEq(
            address(anvil.vrf.coordinator), script.ETHEREUM_VRF_COORDINATOR(), "The lab forks Ethereum's coordinator"
        );
        assertEq(anvil.vrf.keyHash, script.ETHEREUM_VRF_KEY_HASH(), "The lab uses Ethereum's gas lane");

        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        script.deploy(anvil);
        anvil.vrf.subscriptionId = labSubscription;
        vm.expectRevert(Keyfleet.TraitTableHashZero.selector);
        script.deploy(anvil);
        anvil.traitTableHash = TRAIT_TABLE;
        Keyfleet lab = script.deploy(anvil);
        assertGt(address(lab).code.length, 0, "The anvil manifest deploys on its chain");

        vm.setEnv("KEYFLEET_PROTOCOL_TREASURY", vm.toString(REGENTS_SAFE));
        KeyfleetManifest.Manifest memory ethereum = script.readManifest("ethereum", "classic");
        vm.chainId(ETHEREUM_CHAIN_ID);
        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        script.deploy(ethereum);
        ethereum.vrf.subscriptionId = labSubscription;
        ethereum.traitTableHash = TRAIT_TABLE;
        Keyfleet release = script.deploy(ethereum);
        assertGt(address(release).code.length, 0, "The Ethereum manifest deploys");
        assertEq(release.PROTOCOL_TREASURY(), REGENTS_SAFE, "And sends its protocol share to the Regents Safe");
    }

    /// @dev Puts the mock coordinator's code at Ethereum's coordinator address, registers
    /// Ethereum's 200 gwei gas lane there and opens a subscription on it, as the operator does on a
    /// fork.
    function _standInForEthereumCoordinator() private returns (uint256 ethereumSubscription) {
        MockVRFCoordinatorV2Plus ethereum = MockVRFCoordinatorV2Plus(script.ETHEREUM_VRF_COORDINATOR());
        vm.etch(address(ethereum), address(vrf).code);
        ethereum.addProvingKey(script.ETHEREUM_VRF_KEY_HASH(), 200 gwei);
        ethereumSubscription = ethereum.createSubscription();
    }

    /// @dev An Ethereum manifest on Ethereum, paid in Ethereum USDC and answered by Ethereum's VRF
    /// coordinator on its 200 gwei lane, all stood in for by the local mocks' code, with the
    /// Regents Safe as its treasury.
    function _ethereumManifest() private returns (KeyfleetManifest.Manifest memory manifest) {
        vm.chainId(ETHEREUM_CHAIN_ID);
        vm.etch(script.ETHEREUM_USDC(), address(usdc).code);
        uint256 ethereumSubscription = _standInForEthereumCoordinator();
        manifest = _manifest();
        manifest.chainId = ETHEREUM_CHAIN_ID;
        manifest.usdc = script.ETHEREUM_USDC();
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(script.ETHEREUM_VRF_COORDINATOR()),
            subscriptionId: ethereumSubscription,
            keyHash: script.ETHEREUM_VRF_KEY_HASH()
        });
        manifest.protocolTreasury = REGENTS_SAFE;
    }

    function _manifest() private view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.usdc = address(usdc);
        manifest.protocolTreasury = SAFE;
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
        });
        manifest.traitTableHash = TRAIT_TABLE;
        manifest.slot = 2;
        manifest.fleet = KeyfleetManifest.FleetSpec("Keyfleet Classic", "KEYFLEET", "https://k/classic/");
    }
}
