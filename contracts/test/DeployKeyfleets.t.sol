// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";

contract DeployKeyfleetsTest is KeyfleetScriptFixture {
    function setUp() public {
        _setUpScripts();
    }

    /// @dev One run puts the whole system on chain as five deployments from the deploying account,
    /// carrying everything the manifest names, with no fleet and sales closed.
    function test_deployPutsTheSystemOnChainCarryingTheManifest() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        uint256 nonceBefore = vm.getNonce(address(deployScript));

        KeyfleetFactory deployed = deployScript.deploy(manifest);

        assertEq(vm.getNonce(address(deployScript)) - nonceBefore, 5, "Four deployers and the factory");
        KeyfleetKeys collection = deployed.KEYS();
        assertEq(deployed.SAFE(), safe, "Factory's Safe");
        assertEq(collection.SAFE(), safe, "Collection's Safe");
        assertEq(collection.keeper(), keeper, "Keeper");
        assertEq(collection.name(), "Keyfleet", "Name");
        assertEq(collection.symbol(), "KEYFLEET", "Symbol");
        assertEq(collection.baseTokenURI(), manifest.bindings.collection.baseTokenURI, "Metadata base");
        assertEq(collection.contractURI(), manifest.bindings.collection.contractURI, "Collection metadata");
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId, bytes32 keyHash) = collection.randomness();
        assertEq(address(coordinator), address(vrf), "Coordinator");
        assertEq(subscriptionId, vrfSubscription, "Subscription");
        assertEq(keyHash, KEY_HASH, "Gas lane");
        assertEq(collection.TRAIT_TABLE_HASH(), manifest.bindings.traitTableHash, "Trait table");
        assertEq(address(deployed.REGENT_STAKING()), address(staking), "Staking");
        assertEq(address(deployed.AUTOLAUNCH()), address(autolaunch), "Autolaunch");
        KeyfleetRegentBuyer buyer = deployed.REGENT_BUYER();
        assertEq(address(buyer.USDC()), address(usdc), "Route USDC");
        assertEq(address(buyer.V3_POOL()), address(v3Pool), "Route v3 pool");
        assertEq(address(buyer.POOL_MANAGER()), address(poolManager), "Route PoolManager");
        assertEq(collection.fleetCount(), 0, "No fleet yet");
        assertEq(collection.phase(), 0, "Sales closed");
    }

    function test_manifestForAnotherChainIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = 1;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, 1, block.chainid));
        deployScript.deploy(manifest);
    }

    function test_vrfGasLaneTheCoordinatorDoesNotKnowIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.bindings.randomness.keyHash = keccak256("unknown lane");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.VrfKeyHashUnknown.selector, keccak256("unknown lane")));
        deployScript.deploy(manifest);
    }

    function test_vrfSubscriptionTheCoordinatorDoesNotKnowIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.bindings.randomness.subscriptionId = 12_345;
        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        deployScript.deploy(manifest);
    }

    /// @dev What the manifest checks leave out, the contracts refuse while deploying: a zero keeper
    /// or Safe, a zero trait table, staking or Autolaunch without code, a coordinator without code
    /// and a route whose addresses hold no code.
    function test_whatTheContractsCheckThemselvesIsRefusedWhileDeploying() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.bindings.keeper = address(0);
        vm.expectRevert(KeyfleetKeys.ZeroAddress.selector);
        deployScript.deploy(manifest);

        manifest = _manifest();
        manifest.bindings.safe = address(0);
        vm.expectRevert(KeyfleetKeys.ZeroAddress.selector);
        deployScript.deploy(manifest);

        manifest = _manifest();
        manifest.bindings.traitTableHash = bytes32(0);
        vm.expectRevert(KeyfleetKeys.TraitTableHashZero.selector);
        deployScript.deploy(manifest);

        manifest = _manifest();
        manifest.bindings.staking = IRegentRevenueStaking(makeAddr("no staking"));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.BindingMissing.selector, makeAddr("no staking")));
        deployScript.deploy(manifest);

        manifest = _manifest();
        manifest.bindings.route.v3Pool = makeAddr("no pool");
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        deployScript.deploy(manifest);
    }

    /// @dev Invariant: on Base everything a manifest names is Base's own, so no look-alike Safe,
    /// token, pool, hook, staking contract, launch factory, coordinator or gas lane, and no other
    /// collection name, symbol or metadata base, ever reaches the system.
    function test_baseManifestNamingAnythingButBasesOwnIsRefused() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        checks.requireManifestFitsChain(manifest);
        address other = makeAddr("look-alike");

        manifest.bindings.safe = other;
        _expectNotPin(manifest, "safe");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.staking = IRegentRevenueStaking(other);
        _expectNotPin(manifest, "regentStaking");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.autolaunch = autolaunch;
        _expectNotPin(manifest, "autolaunchFactory");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.randomness.coordinator = IVRFCoordinatorV2Plus(address(vrf));
        _expectNotPin(manifest, "vrf.coordinator");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.randomness.keyHash = KEY_HASH;
        _expectNotPin(manifest, "vrf.keyHash");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.collection.name = "KeyFleet";
        _expectNotPin(manifest, "collection.name");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.collection.symbol = "KEYS";
        _expectNotPin(manifest, "collection.symbol");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.collection.baseTokenURI = "https://keyfleet.ai/metadata/";
        _expectNotPin(manifest, "collection.baseTokenURI");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.usdc = address(usdc);
        _expectNotPin(manifest, "route.usdc");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.weth = address(weth);
        _expectNotPin(manifest, "route.weth");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.regent = address(regent);
        _expectNotPin(manifest, "route.regent");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.v3Pool = address(v3Pool);
        _expectNotPin(manifest, "route.v3Pool");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.poolManager = address(poolManager);
        _expectNotPin(manifest, "route.poolManager");
        manifest = _committedBaseManifest(subscriptionId);
        (manifest.bindings.route.v4Pool.currency0, manifest.bindings.route.v4Pool.currency1) =
        (manifest.bindings.route.v4Pool.currency1, manifest.bindings.route.v4Pool.currency0);
        _expectNotPin(manifest, "route.v4Pool.currencies");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.v4Pool.fee = 3000;
        _expectNotPin(manifest, "route.v4Pool.fee");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.v4Pool.tickSpacing = 60;
        _expectNotPin(manifest, "route.v4Pool.tickSpacing");
        manifest = _committedBaseManifest(subscriptionId);
        manifest.bindings.route.v4Pool.hooks = other;
        _expectNotPin(manifest, "route.v4Pool.hooks");
    }

    /// @dev Base's 30 gwei gas lane is the only other lane a Base manifest may name.
    function test_baseManifestMayNameThe30GweiLane() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        bytes32 lane = deployScript.BASE_VRF_KEY_HASH_30_GWEI();
        IVRFCoordinatorV2Plus coordinator = manifest.bindings.randomness.coordinator;
        (bool ok,) = address(coordinator).call(abi.encodeWithSignature("addProvingKey(bytes32,uint64)", lane, 30 gwei));
        assertTrue(ok, "Lane registered");
        manifest.bindings.randomness.keyHash = lane;
        checks.requireManifestFitsChain(manifest);
    }

    /// @dev The committed Base manifest refuses an unknown subscription, then deploys over a
    /// stand-in Base once its subscription exists, preserving the configured keeper.
    function test_committedBaseManifestDeploysOnceItsSubscriptionExists() public {
        _standInBase();
        KeyfleetManifest.Manifest memory committed = deployScript.readManifest("base");
        vm.expectRevert(MockVRFCoordinatorV2Plus.InvalidSubscription.selector);
        deployScript.deploy(committed);

        MockVRFCoordinatorV2Plus(address(committed.bindings.randomness.coordinator))
            .openSubscription(committed.bindings.randomness.subscriptionId, committed.bindings.safe);
        KeyfleetFactory deployed = deployScript.deploy(committed);
        KeyfleetKeys collection = deployed.KEYS();
        assertEq(collection.keeper(), committed.bindings.keeper, "Configured keeper");
        assertEq(collection.name(), "Keyfleet", "Name");
        assertEq(collection.symbol(), "KEYFLEET", "Symbol");
        assertEq(collection.baseTokenURI(), "https://keyfleet.ai/metadata/keys/", "Metadata base");
        assertEq(collection.SAFE(), deployScript.BASE_REGENTS_SAFE(), "Regents Safe");
        assertEq(
            collection.TRAIT_TABLE_HASH(),
            0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe,
            "The published trait table"
        );
        assertEq(
            keccak256(abi.encode(deployed.REGENT_BUYER().v4PoolKey())),
            keccak256(abi.encode(_basePool())),
            "The REGENT pool"
        );
    }

    /// @dev Both committed manifests carry the five founding fleets in founding order with the
    /// founding deck fingerprints, 1,024 cards for Classic #1, 1,000 for the next three and 1,998
    /// for the Regents Club, and
    /// profiles the managers accept.
    function test_committedManifestsCarryTheFoundingDecks() public view {
        bytes32[5] memory decks = [
            bytes32(0x985aa7794cdd1bfdf90d9b68ae557e3e32e343077303ba55d6d7005a981c5818),
            0x1298cf785709867c5397762ba4dfa3d4a1c1394db0cd26444285c48cc6e57706,
            0xbac8510a15a85770ff5cb64b4f0fef57244235ee79327ce3e3e375ce629b6d4d,
            0x2942590c4d3873db390aef50e4648137fdb93729a370105a1aa9a62e43222b66,
            0xae0f753ba8230305e046ff8811b49f86c6024bbbbaa5e40d659d5e5d2698a67b
        ];
        string[2] memory names = ["base", "anvil"];
        for (uint256 file = 0; file < 2; ++file) {
            KeyfleetManifest.Manifest memory manifest = deployScript.readManifest(names[file]);
            for (uint256 index = 0; index < 5; ++index) {
                KeyfleetManifest.FoundingFleet memory fleet = manifest.founding[index];
                assertTrue(fleet.preset == keys.foundingPreset(index + 1), "Founding order");
                assertEq(fleet.deckHash, decks[index], "Deck fingerprint");
                assertEq(fleet.deckSize, index == 0 ? 1024 : index == 4 ? 1998 : 1000, "Deck size");
                assertGt(bytes(fleet.profile.name).length, 0, "Named");
            }
        }
    }

    /// @dev The manifest is read field by field, so the order the file lists its fields in does
    /// not matter.
    function test_manifestIsReadFieldByFieldWhateverItsKeyOrder() public view {
        string memory founding = string.concat(
            "{\"foundingFleets\":{",
            _founding("regentsClub", 5),
            ",",
            _founding("cascade", 4),
            ",",
            _founding("accelerant", 3),
            ",",
            _founding("syndicate", 2),
            ",",
            _founding("classic", 1),
            "},"
        );
        string memory routeJson = string.concat(
            "\"traitTableHash\":\"",
            vm.toString(bytes32(uint256(7))),
            "\",\"route\":{\"v4Pool\":{\"hooks\":\"",
            vm.toString(address(0x55)),
            "\",\"tickSpacing\":-60,\"fee\":3000,\"currency1\":\"",
            vm.toString(address(0x44)),
            "\",\"currency0\":\"",
            vm.toString(address(0x33)),
            "\"},\"poolManager\":\"",
            vm.toString(address(0x22)),
            "\",\"v3Pool\":\"",
            vm.toString(address(0x21)),
            "\",\"regent\":\"",
            vm.toString(address(0x20)),
            "\",\"weth\":\"",
            vm.toString(address(0x19)),
            "\",\"usdc\":\"",
            vm.toString(address(0x18)),
            "\"},"
        );
        string memory json = string.concat(
            founding,
            routeJson,
            "\"vrf\":{\"keyHash\":\"",
            vm.toString(bytes32(uint256(9))),
            "\",\"subscriptionId\":\"115792089237316195423570985008687907853269984665640564039457584007913129639935\",",
            "\"coordinator\":\"",
            vm.toString(address(0x17)),
            "\"},\"collection\":{\"contractURI\":\"c\",\"baseTokenURI\":\"b\",\"symbol\":\"S\",\"name\":\"N\"},",
            "\"regentsClubPass\":\"",
            vm.toString(address(0x12)),
            "\",\"autolaunchFactory\":\"",
            vm.toString(address(0x16)),
            "\",\"regentStaking\":\"",
            vm.toString(address(0x15)),
            "\",\"keeper\":\"",
            vm.toString(address(0x14)),
            "\",\"safe\":\"",
            vm.toString(address(0x13)),
            "\",\"chainId\":10}"
        );

        KeyfleetManifest.Manifest memory manifest = deployScript.parseManifest(json);

        assertEq(manifest.chainId, 10, "Chain");
        assertEq(manifest.bindings.safe, address(0x13), "Safe");
        assertEq(manifest.bindings.keeper, address(0x14), "Keeper");
        assertEq(address(manifest.bindings.staking), address(0x15), "Staking");
        assertEq(address(manifest.bindings.autolaunch), address(0x16), "Autolaunch");
        assertEq(address(manifest.bindings.clubPass), address(0x12), "Regents Club Pass");
        assertEq(manifest.bindings.collection.name, "N", "Name");
        assertEq(manifest.bindings.collection.symbol, "S", "Symbol");
        assertEq(manifest.bindings.collection.baseTokenURI, "b", "Base");
        assertEq(manifest.bindings.collection.contractURI, "c", "Collection metadata");
        assertEq(address(manifest.bindings.randomness.coordinator), address(0x17), "Coordinator");
        assertEq(manifest.bindings.randomness.subscriptionId, type(uint256).max, "A 77-digit subscription id");
        assertEq(manifest.bindings.randomness.keyHash, bytes32(uint256(9)), "Lane");
        assertEq(manifest.bindings.traitTableHash, bytes32(uint256(7)), "Trait table");
        KeyfleetRegentBuyer.Route memory route = manifest.bindings.route;
        assertEq(route.usdc, address(0x18), "USDC");
        assertEq(route.weth, address(0x19), "WETH");
        assertEq(route.regent, address(0x20), "REGENT");
        assertEq(route.v3Pool, address(0x21), "v3 pool");
        assertEq(route.poolManager, address(0x22), "PoolManager");
        assertEq(route.v4Pool.currency0, address(0x33), "currency0");
        assertEq(route.v4Pool.currency1, address(0x44), "currency1");
        assertEq(route.v4Pool.fee, 3000, "Fee");
        assertEq(route.v4Pool.tickSpacing, -60, "Tick spacing");
        assertEq(route.v4Pool.hooks, address(0x55), "Hooks");
        for (uint256 index = 0; index < 5; ++index) {
            KeyfleetManifest.FoundingFleet memory fleet = manifest.founding[index];
            assertTrue(fleet.preset == keys.foundingPreset(index + 1), "Read in founding order");
            assertEq(fleet.deckHash, bytes32(index + 1), "Its own deck");
            assertEq(fleet.deckSize, 1000 + index + 1, "Its own deck size");
            assertEq(fleet.profile.name, string.concat("Fleet ", vm.toString(index + 1)), "Its own name");
            assertEq(fleet.profile.description, "", "An empty description");
            assertEq(fleet.profile.imageLink, "", "No image");
        }
    }

    /// @dev The manifest's founding order is the collection's.
    function test_manifestFoundingOrderIsTheCollections() public view {
        KeyfleetPresets.Preset[5] memory presets = deployScript.foundingPresets();
        for (uint256 index = 0; index < 5; ++index) {
            assertTrue(presets[index] == keys.foundingPreset(index + 1), "Same order");
        }
    }

    function _founding(string memory key, uint256 fleetId) private pure returns (string memory) {
        return string.concat(
            "\"",
            key,
            "\":{\"profile\":{\"imageLink\":\"\",\"description\":\"\",\"name\":\"Fleet ",
            vm.toString(fleetId),
            "\"},\"deckSize\":",
            vm.toString(1000 + fleetId),
            ",\"deckHash\":\"",
            vm.toString(bytes32(fleetId)),
            "\"}"
        );
    }

    function _expectNotPin(KeyfleetManifest.Manifest memory manifest, string memory field) private {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.NotBasePin.selector, field));
        checks.requireManifestFitsChain(manifest);
    }
}
