// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTradingFactory} from "../src/KeyfleetTradingFactory.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {DeployTradingFactory} from "../script/DeployTradingFactory.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../script/KeyfleetSafeSteps.s.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";

/// @dev Answers as `real` does, the collection, shard record, USDC and REGENT revenue staking, but
/// with a Safe of its own.
contract LookAlikeFactory {
    KeyfleetFactory private immutable _real;
    address public immutable SAFE;

    constructor(KeyfleetFactory real, address safe) {
        _real = real;
        SAFE = safe;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function KEYS() external view returns (KeyfleetKeys) {
        return _real.KEYS();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function SHARDS() external view returns (address) {
        return address(_real.SHARDS());
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function USDC() external view returns (address) {
        return address(_real.USDC());
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function REGENT_STAKING() external view returns (address) {
        return address(_real.REGENT_STAKING());
    }
}

contract DeployTradingFactoryTest is KeyfleetScriptFixture {
    DeployTradingFactory private script;

    function setUp() public {
        _setUpScripts();
        script = new DeployTradingFactory();
    }

    /// @dev The trading factory is built on the deployed system: its collection, shard record,
    /// USDC and REGENT revenue staking, with its own three deployers.
    function test_deployBuildsOnTheDeployedSystem() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);

        KeyfleetTradingFactory trading = script.deploy(manifest, deployed);

        assertEq(address(trading.KEYS()), address(deployed.KEYS()), "Collection");
        assertEq(address(trading.SHARDS()), address(deployed.SHARDS()), "Shard record");
        assertEq(address(trading.USDC()), address(deployed.USDC()), "USDC");
        assertEq(address(trading.REGENT_STAKING()), address(deployed.REGENT_STAKING()), "Staking");
        assertGt(address(trading.MANAGER_DEPLOYER()).code.length, 0, "Manager deployer");
        assertGt(address(trading.TREASURY_DEPLOYER()).code.length, 0, "Treasury deployer");
        assertGt(address(trading.REWARDS_DEPLOYER()).code.length, 0, "Ledger deployer");
        assertFalse(deployed.KEYS().isFactory(address(trading)), "Not listed until the Safe adds it");
    }

    /// @dev The Safe's call is the collection's `addFactory` with the trading factory's address;
    /// until the Safe makes it the trading factory creates nothing, and afterwards it creates
    /// Trading Fleets.
    function test_theSafesCallLetsTheTradingFactoryCreateFleets() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);
        while (deployed.KEYS().phase() < deployed.KEYS().FINAL_PHASE()) {
            _openPhase(manifest, deployed);
        }
        KeyfleetTradingFactory trading = script.deploy(manifest, deployed);
        KeyfleetSafeSteps.SafeCall memory call = script.addFactoryCall(trading);

        assertEq(call.name, "add-trading-factory", "Name");
        assertEq(call.to, address(deployed.KEYS()), "To the collection");
        assertEq(call.data, abi.encodeCall(KeyfleetKeys.addFactory, (address(trading))), "addFactory(trading)");

        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms();
        usdc.mint(creator, terms.firstPrice);
        vm.prank(creator);
        usdc.approve(address(trading), terms.firstPrice);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyFactory.selector, address(trading)));
        trading.create(terms);

        KeyfleetSafeSteps.SafeCall[] memory calls = new KeyfleetSafeSteps.SafeCall[](1);
        calls[0] = call;
        _make(calls, manifest.bindings.safe);
        vm.prank(creator);
        (uint256 fleetId,) = trading.create(terms);

        KeyfleetKeys.Fleet memory fleet = deployed.KEYS().fleet(fleetId);
        (address manager,,) = trading.predict(fleetId);
        assertEq(fleet.manager, manager, "Registered by the trading factory");
        assertEq(uint256(fleet.preset), uint256(KeyfleetPresets.Preset.FleetTechAccelerant), "As an Accelerant");
    }

    function test_deployRefusesAFactoryWithoutCode() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        address nothing = makeAddr("nothing");
        vm.expectRevert(abi.encodeWithSelector(DeployTradingFactory.FactoryMissing.selector, nothing));
        script.deploy(manifest, KeyfleetFactory(nothing));
    }

    function test_deployRefusesAManifestForAnotherChain() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        manifest.chainId = 1;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, 1, block.chainid));
        script.deploy(manifest, deployed);
    }

    /// @dev A factory whose collection is not the manifest's, by its Safe, name, symbol, metadata
    /// links or trait table, gets no trading factory.
    function test_deployRefusesACollectionThatIsNotTheManifests() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);

        manifest.bindings.safe = makeAddr("other");
        _expectCollectionMismatch(manifest, deployed, "safe");
        manifest = _manifest();
        manifest.bindings.collection.name = "Other";
        _expectCollectionMismatch(manifest, deployed, "name");
        manifest = _manifest();
        manifest.bindings.collection.symbol = "OTHER";
        _expectCollectionMismatch(manifest, deployed, "symbol");
        manifest = _manifest();
        manifest.bindings.collection.baseTokenURI = "https://example.com/keys/";
        _expectCollectionMismatch(manifest, deployed, "baseTokenURI");
        manifest = _manifest();
        manifest.bindings.collection.contractURI = "https://example.com/collection.json";
        _expectCollectionMismatch(manifest, deployed, "contractURI");
        manifest = _manifest();
        manifest.bindings.traitTableHash = keccak256("other table");
        _expectCollectionMismatch(manifest, deployed, "traitTableHash");
    }

    /// @dev A contract that answers as the factory of the deployed system, with its collection and
    /// every binding, gets no trading factory while the collection does not list it; once the Safe
    /// lists it, its own Safe must still be the manifest's.
    function test_deployRefusesAFactoryItsCollectionDoesNotList() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        KeyfleetKeys collection = deployed.KEYS();
        LookAlikeFactory lookAlike = new LookAlikeFactory(deployed, makeAddr("other safe"));

        vm.expectRevert(
            abi.encodeWithSelector(DeployTradingFactory.FactoryNotListed.selector, lookAlike, address(collection))
        );
        script.deploy(manifest, KeyfleetFactory(address(lookAlike)));

        vm.prank(manifest.bindings.safe);
        collection.addFactory(address(lookAlike));
        _expectMismatch(manifest, KeyfleetFactory(address(lookAlike)), "safe");
    }

    /// @dev On Base only the live collection's factory gets a trading factory: a whole system
    /// deployed from the committed Base manifest, at any other address, is refused.
    function test_onBaseTheDeployRefusesEveryCollectionButTheLiveOne() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory deployed = deployScript.deploy(manifest);
        assertTrue(address(deployed.KEYS()) != script.BASE_KEYFLEET_COLLECTION());

        vm.expectRevert(
            abi.encodeWithSelector(DeployTradingFactory.CollectionNotPinned.selector, address(deployed.KEYS()))
        );
        script.deploy(manifest, deployed);
    }

    /// @dev A factory that is not the manifest's, by its REGENT revenue staking or its USDC, gets
    /// no trading factory.
    function test_deployRefusesAFactoryThatIsNotTheManifests() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        address other = makeAddr("other");

        manifest.bindings.staking = IRegentRevenueStaking(other);
        _expectMismatch(manifest, deployed, "regentStaking");
        manifest = _manifest();
        manifest.bindings.route.usdc = other;
        _expectMismatch(manifest, deployed, "route.usdc");
    }

    function _expectCollectionMismatch(
        KeyfleetManifest.Manifest memory manifest,
        KeyfleetFactory deployed,
        string memory field
    ) private {
        vm.expectRevert(abi.encodeWithSelector(DeployTradingFactory.CollectionMismatch.selector, field));
        script.deploy(manifest, deployed);
    }

    function _expectMismatch(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory deployed, string memory field)
        private
    {
        vm.expectRevert(abi.encodeWithSelector(DeployTradingFactory.FactoryMismatch.selector, field));
        script.deploy(manifest, deployed);
    }

    /// @dev Terms of 10 USDC first, a 5% step and a 1% daily payback, open to anyone.
    function _tradingTerms() private view returns (KeyfleetTradingFactory.TradingTerms memory terms) {
        terms.profile = _profile("Trading fleet");
        terms.firstPrice = 10e6;
        terms.stepBps = 500;
        terms.dailyPaybackBps = 100;
        terms.deadline = block.timestamp;
    }
}
