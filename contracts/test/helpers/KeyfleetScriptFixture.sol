// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {V4PoolKey} from "../../src/interfaces/IUniswapV4PoolManager.sol";
import {DeployKeyfleets} from "../../script/DeployKeyfleets.s.sol";
import {KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {KeyfleetFixture} from "./KeyfleetFixture.sol";
import {MockAutolaunchFactory} from "../mocks/MockAutolaunchFactory.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockRegent} from "../mocks/MockRegent.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";
import {MockWeth} from "../mocks/MockWeth.sol";

/// @dev Exposes the manifest checks the deployment steps run first.
contract ManifestChecks is DeployKeyfleets {
    function requireManifestFitsChain(Manifest memory manifest) external view {
        _requireManifestFitsChain(manifest);
    }
}

/// @dev The deployment steps run as their scripts run them, on the fixture's stand-ins, with
/// manifests built from the fixture's bindings, and a stand-in Base whose pinned addresses hold
/// the stand-ins' code.
abstract contract KeyfleetScriptFixture is KeyfleetFixture {
    /// @dev The fixture's VRF gas lane, which the stand-in coordinator is told it knows.
    bytes32 internal constant KEY_HASH = keccak256("key hash");

    DeployKeyfleets internal deployScript;
    KeyfleetSafeSteps internal safeSteps;
    ManifestChecks internal checks;

    function _setUpScripts() internal {
        _setUpFixture();
        vrf.addProvingKey(KEY_HASH, 30 gwei);
        deployScript = new DeployKeyfleets();
        safeSteps = new KeyfleetSafeSteps();
        checks = new ManifestChecks();
    }

    /// @dev A manifest for this chain naming the fixture's stand-ins, with four founding fleets.
    function _manifest() internal view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = block.chainid;
        manifest.bindings = _bindings();
        string[4] memory names = ["Classic #1", "Syndicate #1", "Accelerant #1", "Cascade #1"];
        for (uint256 index = 0; index < 4; ++index) {
            manifest.founding[index] = KeyfleetManifest.FoundingFleet({
                preset: deployScript.foundingPresets()[index],
                deckHash: _deckHash(index + 1),
                deckSize: DECK_SIZE,
                profile: _profile(names[index])
            });
        }
    }

    /// @dev Deploys the manifest's system through the deployment step and lists its collection on
    /// the subscription, as the Safe does.
    function _deployListed(KeyfleetManifest.Manifest memory manifest) internal returns (KeyfleetFactory deployed) {
        deployed = deployScript.deploy(manifest);
        _listConsumer(manifest, deployed.KEYS());
    }

    function _listConsumer(KeyfleetManifest.Manifest memory manifest, KeyfleetKeys collection) internal {
        MockVRFCoordinatorV2Plus coordinator =
            MockVRFCoordinatorV2Plus(address(manifest.bindings.randomness.coordinator));
        vm.prank(coordinator.subscriptionOwner(manifest.bindings.randomness.subscriptionId));
        coordinator.addConsumer(manifest.bindings.randomness.subscriptionId, address(collection));
    }

    /// @dev Makes every call the Safe step returns, from `from`, in order.
    function _make(KeyfleetSafeSteps.SafeCall[] memory calls, address from) internal {
        for (uint256 index = 0; index < calls.length; ++index) {
            vm.prank(from);
            (bool ok, bytes memory reason) = calls[index].to.call(calls[index].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    /// @dev Creates every founding fleet through the Safe step, as the Safe.
    function _found(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory deployed) internal {
        _make(safeSteps.foundingFleetCalls(manifest, deployed), manifest.bindings.safe);
    }

    /// @dev Moves the collection one phase on through the Safe's phase step, opening a second from
    /// now, and waits for that second.
    function _openPhase(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory deployed) internal {
        _make(safeSteps.advancePhaseCalls(manifest, deployed, uint64(block.timestamp + 1)), manifest.bindings.safe);
        vm.warp(block.timestamp + 1);
    }

    // --- a stand-in Base ---------------------------------------------------

    /// @dev Moves to Base and puts stand-in code at every address a Base manifest pins: the route's
    /// tokens and pools at the stand-in market price, REGENT staking, the Autolaunch factory, and a
    /// coordinator that knows Base's 2 gwei lane and a subscription the Regents Safe owns. Returns
    /// that subscription.
    function _standInBase() internal returns (uint256 subscriptionId) {
        KeyfleetManifest pins = deployScript;
        vm.chainId(pins.BASE_CHAIN_ID());
        address baseUsdc = pins.BASE_USDC();
        address baseWeth = pins.BASE_WETH();
        address baseRegent = pins.BASE_REGENT();
        vm.etch(baseUsdc, address(new MockToken("USD Coin", "USDC")).code);
        vm.etch(baseWeth, address(new MockWeth()).code);
        vm.etch(baseRegent, address(new MockRegent()).code);

        MockUniswapV3Pool pool = MockUniswapV3Pool(pins.BASE_USDC_WETH_POOL());
        vm.etch(address(pool), address(new MockUniswapV3Pool(baseUsdc, baseWeth, WETH_PER_USDC, USDC_PER_WETH)).code);
        pool.setFillBps(10_000);
        MockPoolManager manager = MockPoolManager(pins.BASE_POOL_MANAGER());
        vm.etch(address(manager), address(new MockPoolManager(baseWeth, REGENT_PER_WETH, WETH_PER_REGENT)).code);
        manager.setFillBps(10_000);
        MockWeth(baseWeth).mint(address(pool), 1e36);
        MockRegent(baseRegent).mint(address(manager), 1e45);

        vm.etch(pins.BASE_REGENT_REVENUE_STAKING(), address(new MockRegentRevenueStaking(MockToken(baseUsdc))).code);
        vm.etch(pins.BASE_AUTOLAUNCH_FACTORY(), address(new MockAutolaunchFactory()).code);

        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(pins.BASE_VRF_COORDINATOR());
        vm.etch(address(coordinator), address(new MockVRFCoordinatorV2Plus()).code);
        coordinator.addProvingKey(pins.BASE_VRF_KEY_HASH_2_GWEI(), 2 gwei);
        subscriptionId = 77;
        coordinator.openSubscription(subscriptionId, pins.BASE_REGENTS_SAFE());
    }

    /// @dev The committed Base manifest, with the stand-in Base's subscription and a keeper
    /// written in.
    function _committedBaseManifest(uint256 subscriptionId)
        internal
        view
        returns (KeyfleetManifest.Manifest memory manifest)
    {
        manifest = deployScript.readManifest("base");
        manifest.bindings.randomness.subscriptionId = subscriptionId;
        manifest.bindings.keeper = keeper;
    }

    /// @dev The Base v4 pool key the manifest pins.
    function _basePool() internal view returns (V4PoolKey memory) {
        return V4PoolKey({
            currency0: deployScript.BASE_WETH(),
            currency1: deployScript.BASE_REGENT(),
            fee: deployScript.BASE_REGENT_POOL_FEE(),
            tickSpacing: deployScript.BASE_REGENT_POOL_TICK_SPACING(),
            hooks: deployScript.BASE_REGENT_POOL_HOOKS()
        });
    }

    /// @dev The manager of `deployed`'s fleet `fleetId`.
    function _managerOf(KeyfleetFactory deployed, uint256 fleetId) internal view returns (KeyfleetManager) {
        return KeyfleetManager(deployed.KEYS().managerOf(fleetId));
    }
}
