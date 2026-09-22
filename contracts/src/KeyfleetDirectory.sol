// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";

/// @notice The four fixed fleets of the release, named once and never again.
/// @dev This is the whole of the "minimal deployment factory/registry" the release asks for. It
/// deploys nothing: `Keyfleet` initcode is 38,025 bytes, so a contract carrying a `new Keyfleet`
/// would exceed the 24,576-byte runtime limit, and a constructor deploying all four would exceed
/// the 49,152-byte initcode limit. The deployment script creates the fleets and this contract
/// records which four they are, so the app seeds from one address instead of four pasted ones.
///
/// The constructor is the only check there is: each slot must hold the preset that belongs to it,
/// and all four must share the same REGENT, treasury, asset registry, staking contract, Autolaunch
/// factory and voting window. A directory therefore only ever names a coherent set. USDC needs no
/// comparison of its own: a fleet refuses any USDC but its registry's `BASE_USDC`, and the registry
/// is compared. The fleets themselves are unchanged by it: it holds no authority over any of them,
/// takes no tokens, and a later factory reading a fleet's public immutables learns exactly what
/// this contract learned.
///
/// There is no owner, no setter, no way to add or remove a fleet, and no upgrade path. A different
/// set of fleets means a different directory.
contract KeyfleetDirectory {
    /// @notice The fleet in `slot` does not belong in this directory: its preset is not the one the
    /// slot is for, or one of its six shared values differs from slot 0's.
    error FleetMismatch(uint8 slot);

    /// @notice Fibonacci Syndicate, slot 0.
    Keyfleet public immutable SYNDICATE;
    /// @notice Fibonacci Cascade, slot 1.
    Keyfleet public immutable CASCADE;
    /// @notice Fleet.Tech Classic, slot 2.
    Keyfleet public immutable CLASSIC;
    /// @notice Fleet.Tech Accelerant, slot 3.
    Keyfleet public immutable ACCELERANT;

    /// @notice Records the four fleets after checking that they form a coherent set.
    /// @dev Slot 0 is the reference the other three are compared against; its own preset is checked
    /// like everyone else's. A fleet's `Q`, name, symbol and metadata base are deliberately not
    /// compared: they differ per fleet by design.
    /// @param syndicate A fleet whose preset is `FibonacciSyndicate`.
    /// @param cascade A fleet whose preset is `FibonacciCascade`.
    /// @param classic A fleet whose preset is `FleetTechClassic`.
    /// @param accelerant A fleet whose preset is `FleetTechAccelerant`.
    constructor(Keyfleet syndicate, Keyfleet cascade, Keyfleet classic, Keyfleet accelerant) {
        _requirePreset(syndicate, KeyfleetPresets.Preset.FibonacciSyndicate, 0);
        _requirePreset(cascade, KeyfleetPresets.Preset.FibonacciCascade, 1);
        _requirePreset(classic, KeyfleetPresets.Preset.FleetTechClassic, 2);
        _requirePreset(accelerant, KeyfleetPresets.Preset.FleetTechAccelerant, 3);

        _requireSameWiring(syndicate, cascade, 1);
        _requireSameWiring(syndicate, classic, 2);
        _requireSameWiring(syndicate, accelerant, 3);

        SYNDICATE = syndicate;
        CASCADE = cascade;
        CLASSIC = classic;
        ACCELERANT = accelerant;
    }

    /// @notice The four fleets in slot order: Syndicate, Cascade, Classic, Accelerant.
    function fleets() external view returns (Keyfleet[4] memory) {
        return [SYNDICATE, CASCADE, CLASSIC, ACCELERANT];
    }

    /// @notice Whether an address is one of this directory's four fleets.
    function isFleet(address account) external view returns (bool) {
        return account == address(SYNDICATE) || account == address(CASCADE) || account == address(CLASSIC)
            || account == address(ACCELERANT);
    }

    function _requirePreset(Keyfleet fleet, KeyfleetPresets.Preset expected, uint8 slot) private view {
        if (fleet.PRESET() != expected) revert FleetMismatch(slot);
    }

    /// @dev The six values every fleet of one release shares. A difference in any of them means the
    /// two fleets answer to different money, a different treasury, a different admission list or a
    /// different vote clock, and are not the same release.
    function _requireSameWiring(Keyfleet anchor, Keyfleet fleet, uint8 slot) private view {
        if (
            fleet.REGENT() != anchor.REGENT() || fleet.TREASURY() != anchor.TREASURY()
                || fleet.ASSET_REGISTRY() != anchor.ASSET_REGISTRY() || fleet.STAKING() != anchor.STAKING()
                || fleet.FACTORY() != anchor.FACTORY()
                || fleet.VOTES().VOTING_WINDOW() != anchor.VOTES().VOTING_WINDOW()
        ) {
            revert FleetMismatch(slot);
        }
    }
}
