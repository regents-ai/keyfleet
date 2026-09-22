// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetDirectory} from "../src/KeyfleetDirectory.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

/// @dev The directory only reads fleets, so the staking contract and the Autolaunch factory are
/// bare addresses here: a fleet stores both without calling either at construction.
contract KeyfleetDirectoryTest is Test {
    uint256 private constant Q = 10e18;
    uint64 private constant VOTING_WINDOW = 24 hours;

    MockToken private regent;
    MockToken private usdc;
    KeyfleetAssetRegistry private registry;

    address private constant SAFE = address(0x5AFE);
    address private constant TREASURY = address(0x7EA5);
    address private constant STAKING = address(0x57A1);
    address private constant FACTORY = address(0xFAC7);

    /// @dev The values a directory requires every fleet to share, so a test changes exactly one.
    struct Wiring {
        MockToken regent;
        address treasury;
        KeyfleetAssetRegistry registry;
        address staking;
        address factory;
        uint64 votingWindow;
    }

    Keyfleet private syndicate;
    Keyfleet private cascade;
    Keyfleet private classic;
    Keyfleet private accelerant;

    function setUp() public {
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        registry = new KeyfleetAssetRegistry(SAFE, address(usdc));

        syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate, _wiring());
        cascade = _deploy(KeyfleetPresets.Preset.FibonacciCascade, _wiring());
        classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic, _wiring());
        accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant, _wiring());
    }

    function test_coherentSetIsRecordedInSlotOrder() public {
        KeyfleetDirectory directory = new KeyfleetDirectory(syndicate, cascade, classic, accelerant);

        assertEq(address(directory.SYNDICATE()), address(syndicate), "Slot 0");
        assertEq(address(directory.CASCADE()), address(cascade), "Slot 1");
        assertEq(address(directory.CLASSIC()), address(classic), "Slot 2");
        assertEq(address(directory.ACCELERANT()), address(accelerant), "Slot 3");

        Keyfleet[4] memory fleets = directory.fleets();
        assertEq(address(fleets[0]), address(syndicate), "fleets()[0]");
        assertEq(address(fleets[1]), address(cascade), "fleets()[1]");
        assertEq(address(fleets[2]), address(classic), "fleets()[2]");
        assertEq(address(fleets[3]), address(accelerant), "fleets()[3]");

        assertTrue(directory.isFleet(address(syndicate)), "Syndicate is a fleet");
        assertTrue(directory.isFleet(address(cascade)), "Cascade is a fleet");
        assertTrue(directory.isFleet(address(classic)), "Classic is a fleet");
        assertTrue(directory.isFleet(address(accelerant)), "Accelerant is a fleet");
    }

    function test_everySlotRefusesAFleetOfAnotherPreset() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(0)));
        new KeyfleetDirectory(cascade, cascade, classic, accelerant);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(1)));
        new KeyfleetDirectory(syndicate, syndicate, classic, accelerant);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(2)));
        new KeyfleetDirectory(syndicate, cascade, accelerant, accelerant);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(3)));
        new KeyfleetDirectory(syndicate, cascade, classic, classic);
    }

    function test_fleetPaidInADifferentRegentIsRefused() public {
        Wiring memory wiring = _wiring();
        wiring.regent = new MockToken("Other Regent", "REGENT");
        Keyfleet stray = _deploy(KeyfleetPresets.Preset.FibonacciCascade, wiring);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(1)));
        new KeyfleetDirectory(syndicate, stray, classic, accelerant);
    }

    function test_fleetReportingToADifferentStakingContractIsRefused() public {
        Wiring memory wiring = _wiring();
        wiring.staking = address(0xBEEF);
        Keyfleet stray = _deploy(KeyfleetPresets.Preset.FleetTechClassic, wiring);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(2)));
        new KeyfleetDirectory(syndicate, cascade, stray, accelerant);
    }

    function test_fleetWithADifferentVotingWindowIsRefused() public {
        Wiring memory wiring = _wiring();
        wiring.votingWindow = 1 hours;
        Keyfleet stray = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant, wiring);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(3)));
        new KeyfleetDirectory(syndicate, cascade, classic, stray);
    }

    function test_fleetPayingADifferentTreasuryIsRefused() public {
        Wiring memory wiring = _wiring();
        wiring.treasury = address(0xBEEF);
        Keyfleet stray = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant, wiring);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(3)));
        new KeyfleetDirectory(syndicate, cascade, classic, stray);
    }

    function test_fleetPinnedToADifferentAutolaunchFactoryIsRefused() public {
        Wiring memory wiring = _wiring();
        wiring.factory = address(0xBEEF);
        Keyfleet stray = _deploy(KeyfleetPresets.Preset.FibonacciCascade, wiring);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(1)));
        new KeyfleetDirectory(syndicate, stray, classic, accelerant);
    }

    function test_fleetAnsweringToADifferentAssetRegistryIsRefused() public {
        Wiring memory wiring = _wiring();
        wiring.registry = new KeyfleetAssetRegistry(SAFE, address(usdc));
        Keyfleet stray = _deploy(KeyfleetPresets.Preset.FleetTechClassic, wiring);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetDirectory.FleetMismatch.selector, uint8(2)));
        new KeyfleetDirectory(syndicate, cascade, stray, accelerant);
    }

    function testFuzz_strangerIsNotAFleet(address stranger) public {
        KeyfleetDirectory directory = new KeyfleetDirectory(syndicate, cascade, classic, accelerant);
        vm.assume(
            stranger != address(syndicate) && stranger != address(cascade) && stranger != address(classic)
                && stranger != address(accelerant)
        );

        assertFalse(directory.isFleet(stranger), "Only the four fleets are fleets");
    }

    function _wiring() private view returns (Wiring memory) {
        return Wiring({
            regent: regent,
            treasury: TREASURY,
            registry: registry,
            staking: STAKING,
            factory: FACTORY,
            votingWindow: VOTING_WINDOW
        });
    }

    function _deploy(KeyfleetPresets.Preset preset, Wiring memory wiring) private returns (Keyfleet) {
        return new Keyfleet(
            preset,
            Q,
            IERC20(address(wiring.regent)),
            IERC20(address(usdc)),
            wiring.treasury,
            wiring.registry,
            IRegentRevenueStaking(wiring.staking),
            IRegentsAutolaunchFactoryV1(wiring.factory),
            wiring.votingWindow,
            Keyfleet.Metadata({name: "Fleet Keys", symbol: "KEY", baseTokenURI: "https://keys.example/"})
        );
    }
}
